#!/usr/bin/env bash
# 宿主侧内存哨兵 v3 —— 防止试跑把节点打到 wedge（需强制断电）
#
# 为什么需要：GB10 是统一内存，运行时编译 + 推理抢同一池子。
# 一旦触顶，内核进入 reclaim thrash，连 sshd 都无法完成 SSH 握手，
# 表现为「ping 通、TCP 22 接受、SSH banner 超时」，只能断电。
#
# v2 相对 v1 的改进：加了 PSI（内核内存压力）触发。
# 只看 MemAvailable 会晚——reclaim 开始挣扎时它可能还显示不少；
# PSI 的 full avg10 是「所有任务都被内存卡住」的占比，thrash 一发生就抬头。
# v3（2026-09-12 内存安全链修复）：启动失败必须回非零（不再谎报"已启动"）、
#   强制钳制 1024 MB 绝对下限、触发时协调四台清场、日志不再清空丢证据。
# v4（2026-09-13）：废除 PSI 单腿。spark-03 稳态 psi>5 在 avail 仍 7–11 GB 时
#   两次清场（00:17 PSI 8.87 / 21:37 PSI 16.09）。现役杀判据与加载期对齐：
#   avail < THRESH(>=1024)  OR  (avail < 16384 AND psi_full > 50)。
#   位置参数 PSI_full / PSI_some 不再单独开火（保留只为兼容旧调用）。
#
# 用法：
#   memguard.sh start <容器名> [可用内存阈值MB] [采样秒] [PSI_full阈值] [PSI_some阈值]
#   memguard.sh stop | status
# 默认阈值：8192 MB（现役调用方传 1024）/ 1 s；PSI 合取硬编码 16384/50（env 可覆盖）
#
# 退出码：0 成功 / 2 参数非法 / 3 **哨兵未能拉起（调用方必须据此拒绝起服）**
set -uo pipefail

ACTION="${1:-status}"

if [ "$ACTION" = "__watch" ]; then
  LOG="${_MG_LOG:-/home/cq/logs/memguard.log}"
  NAME="${_MG_NAME:-}"
  THRESH_MB="${_MG_THRESH:-8192}"
  INTERVAL="${_MG_INTERVAL:-1}"
  PSI_FULL="${_MG_PSI_FULL:-5.0}"
  PSI_SOME="${_MG_PSI_SOME:-60.0}"
  PSI_AND="${_MG_PSI_AND:-50.0}"
  PSI_AND_ABS="${_MG_PSI_AND_ABS:-16384}"
else
  NAME="${2:-}"
  THRESH_MB="${3:-8192}"
  INTERVAL="${4:-1}"
  PSI_FULL="${5:-5.0}"
  PSI_SOME="${6:-60.0}"
  PSI_AND="${V41_MG_PSI_HARD:-50.0}"
  PSI_AND_ABS="${V41_MG_PSI_HARD_ABS:-16384}"
fi

# ---- S3-1：绝对下限硬钳制（不得放宽 1024）----------------------------------
case "${THRESH_MB:-}" in
  ''|*[!0-9]*) echo "!! THRESH_MB 非法：'${THRESH_MB:-}'（必须为十进制整数）" >&2; exit 2 ;;
esac
if [ "$THRESH_MB" -lt 1024 ]; then
  echo "!! THRESH_MB=${THRESH_MB} 低于硬约束下限 1024，已强制抬回 1024（不得放宽）" >&2
  THRESH_MB=1024
fi
case "${PSI_AND_ABS:-}" in
  ''|*[!0-9]*) PSI_AND_ABS=16384 ;;
esac

PIDFILE="/home/cq/logs/memguard-${NAME}.pid"
LOGDIR="/home/cq/logs"
LOG="${_MG_LOG:-$LOGDIR/memguard.log}"

mkdir -p "$LOGDIR"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }

read_mem() {
  awk '/^MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null
}
# 取 PSI full avg10（无 PSI 时输出 0）
read_psi_full() {
  awk '/^full / {for(i=1;i<=NF;i++) if($i ~ /^avg10=/){sub("avg10=","",$i); print $i; exit}}' \
    /proc/pressure/memory 2>/dev/null || echo 0
}
read_psi_some() {
  awk '/^some / {for(i=1;i<=NF;i++) if($i ~ /^avg10=/){sub("avg10=","",$i); print $i; exit}}' \
    /proc/pressure/memory 2>/dev/null || echo 0
}

# ---- S2-4：跨四台协调清场（避免 head 死/worker 活半死态）---------------------
COORD="/home/cq/v41-kill-all.sh"
self_is_head() { ip -4 -o addr show 2>/dev/null | grep -q '10\.100\.24\.4'; }

kill_container() {
  docker kill "$NAME" >/dev/null 2>&1 || true
  if [ -x "$COORD" ]; then
    log "启动四台协调清场（$COORD）……"
    if self_is_head; then
      timeout 40 bash "$COORD" "$NAME" >>"$LOG" 2>&1 && log "四台清场完成" \
        || log "!! 四台清场失败（已按本机保底；可能残留半死态）"
    else
      timeout 40 ssh -n -o BatchMode=yes -o ConnectTimeout=5 cq@10.100.24.4 "bash $COORD $NAME" >>"$LOG" 2>&1 \
        && log "四台清场完成" || log "!! 四台清场 ssh 失败（已按本机保底；可能残留半死态）"
    fi
  fi
  sleep 3
  if docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
    log "容器仍在，docker rm -f"
    docker rm -f "$NAME" >/dev/null 2>&1
  fi
}

case "$ACTION" in
  stop)
    if [ -f "$PIDFILE" ]; then
      read -r pid rest < "$PIDFILE" || true
      [ -n "${pid:-}" ] && kill "$pid" 2>/dev/null && echo "已停止哨兵 pid=$pid" || echo "哨兵不在运行"
      rm -f "$PIDFILE"
    else
      pkill -f "[m]emguard\.sh __watch $NAME" 2>/dev/null && echo "已停止" || echo "哨兵不在运行"
    fi
    exit 0
    ;;

  status)
    if [ -f "$PIDFILE" ]; then
      read -r pid cname < "$PIDFILE" || true
      if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
        echo "哨兵运行中 pid=$pid 容器=${cname:-?}"
        tail -4 "$LOGDIR/memguard-${cname:-x}.log" 2>/dev/null || true
      else
        echo "哨兵未运行（stale pidfile）"
      fi
    else
      echo "哨兵未运行"
    fi
    exit 0
    ;;

  start)
    [ -n "$NAME" ] || { echo "需要容器名" >&2; exit 2; }
    LOG="$LOGDIR/memguard-$NAME.log"
    if [ -f "$PIDFILE" ] && kill -0 "$(read -r p _ < "$PIDFILE"; echo "$p")" 2>/dev/null; then
      echo "已有哨兵在跑，先 stop"
      exit 2
    fi
    setsid nohup env _MG_LOG="$LOG" _MG_NAME="$NAME" _MG_THRESH="$THRESH_MB" \
      _MG_INTERVAL="$INTERVAL" _MG_PSI_FULL="$PSI_FULL" _MG_PSI_SOME="$PSI_SOME" \
      _MG_PSI_AND="$PSI_AND" _MG_PSI_AND_ABS="$PSI_AND_ABS" \
      "$0" __watch "$NAME" > /dev/null 2>&1 < /dev/null &
    sleep 1
    pid=$(pgrep -f "[m]emguard\.sh __watch $NAME" | head -1 || true)
    if [ -z "${pid:-}" ]; then
      # S1-1：绝不谎报成功。
      pkill -f "[m]emguard\.sh __watch $NAME" 2>/dev/null || true
      rm -f "$PIDFILE"
      echo "!! 稳定期哨兵启动失败：未发现 __watch 进程（容器=$NAME）。调用方必须据此拒绝起服。" >&2
      exit 3
    fi
    printf '%s %s\n' "$pid" "$NAME" > "$PIDFILE"
    echo "哨兵已启动 pid=$pid 容器=$NAME 阈值=${THRESH_MB}MB 采样=${INTERVAL}s 合取=(avail<${PSI_AND_ABS}MB AND psi_full>${PSI_AND})（PSI 单腿已废）"
    echo "日志：$LOG"
    exit 0
    ;;

  __watch)
    # S3-7：不再 : > "$LOG" 清空日志，改为追加分隔行（保留触发证据）。
    if [ -f "$LOG" ]; then
      printf '\n[%s] ---- 稳定期哨兵重启（保留历史触发证据）----\n' "$(date '+%F %T')" >> "$LOG" 2>/dev/null || true
    fi
    log "哨兵启动：容器=$NAME 阈值=${THRESH_MB}MB 采样=${INTERVAL}s 合取=(avail<${PSI_AND_ABS}MB AND psi_full>${PSI_AND})（PSI 单腿已废）"
    tick=0
    while true; do
      avail=$(read_mem); [ -n "$avail" ] || { sleep "$INTERVAL"; continue; }
      pf=$(read_psi_full); ps=$(read_psi_some)

      tick=$((tick + 1))
      if [ $((tick % 15)) -eq 0 ]; then
        log "水位 avail=${avail}MB psi_full=${pf} psi_some=${ps}"
      fi

      fire=""
      case "${avail:-0}" in *[!0-9]*) avail=0;; esac
      if [ "$avail" -lt "$THRESH_MB" ]; then
        fire="MemAvailable ${avail}MB < ${THRESH_MB}MB"
      elif [ "$avail" -lt "$PSI_AND_ABS" ] && awk -v a="$pf" -v b="$PSI_AND" 'BEGIN{exit !(a+0 > b+0)}'; then
        fire="合取触发：avail ${avail}MB < ${PSI_AND_ABS}MB 且 PSI full avg10=${pf} > ${PSI_AND}（真 thrash）"
      fi

      if [ -n "$fire" ]; then
        log "!! 触发：$fire —— 立即杀掉容器 $NAME 以防 wedge"
        log "   触发前水位 avail=${avail}MB psi_full=${pf} psi_some=${ps}"
        kill_container
        a2=$(read_mem); f2=$(read_psi_full)
        log "杀后水位 avail=${a2}MB psi_full=${f2}"
        log "哨兵任务完成，退出"
        rm -f "$PIDFILE"
        exit 0
      fi
      sleep "$INTERVAL"
    done
    ;;

  *)
    echo "usage: memguard.sh start <容器名> [阈值MB] [采样秒] [PSI_full] [PSI_some] | stop | status"
    exit 2
    ;;
esac
