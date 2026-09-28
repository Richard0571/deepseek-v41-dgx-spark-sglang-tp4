#!/usr/bin/env bash
# v41-mg-load.sh — 加载期专用内存哨兵（双条件 OR：绝对下限 独立支 + 合取支）
#
# 为什么要这个而不是 memguard.sh：
#   memguard.sh 的 PSI 判据是给"稳态"用的。加载期读 475 GiB checkpoint 到只剩 ~21 GiB
#   可用的机器上，内核必然反复回收页缓存，PSI full 结构性抬头（实测 avail 还有 11~20 GB
#   时 PSI 已到 20+；本机实测加载期峰值 28~40）。单看 PSI 会误杀。
#
#   真正危险的是「PSI 高 **且** 绝对余量也贴近下限」。所以本哨兵在加载期用：
#     杀 = avail < ABS_MB                                        （绝对下限，防 wedge 底保险）
#        OR (avail < PSI_HARD_ABS_MB AND psi_full > PSI_HARD)     （真 thrash 才杀）
#   ⚠️ 准确表述：绝对下限是**独立 OR 支**；只有 PSI 那一支是合取。见 __watch 内实现。
#
#   PSI_HARD 默认 50：实测加载期 PSI 在 avail 11~20 GB 段饱和在 20~21，取 50 留出 2.4x 余量，
#   既不会被翻搅误杀，又能在真的开始穷尽时（PSI 冲到 50+）兜住。
#
# 硬约束（spark-trial-safety）：1024 MB 绝对下限**不得放宽、不得停用**。
#   本脚本在启动时强制钳制：ABS_MB 非数字 → 退出 2；ABS_MB < 1024 → 抬回 1024。
#
# 用法：
#   v41-mg-load.sh start <容器名> [ABS_MB=8192] [采样秒=2] [PSI_HARD=50.0] [PSI_HARD_ABS_MB=16384]
#   v41-mg-load.sh stop  <容器名>
#   v41-mg-load.sh status <容器名>
#
# 退出码：0 成功 / 2 参数非法 / 3 **哨兵未能拉起（调用方必须据此拒绝起服）**
# 日志：/home/cq/logs/memguard-load-<容器名>.log
set -uo pipefail

ACTION="${1:-status}"

if [ "$ACTION" = "__watch" ]; then
  NAME="${_ML_NAME:-}"
  ABS_MB="${_ML_ABS:-8192}"
  INTERVAL="${_ML_INTERVAL:-2}"
  PSI_HARD="${_ML_PSI_HARD:-50.0}"
  PSI_HARD_ABS="${_ML_PSI_HARD_ABS:-16384}"
  LOG="${_ML_LOG:-/home/cq/logs/memguard-load-${NAME}.log}"
else
  NAME="${2:-}"
  ABS_MB="${3:-8192}"
  INTERVAL="${4:-2}"
  PSI_HARD="${5:-50.0}"
  PSI_HARD_ABS="${6:-16384}"
  LOG="/home/cq/logs/memguard-load-${NAME}.log"
fi

# ---- S3-1：绝对下限硬钳制（不得放宽 1024）----------------------------------
case "${ABS_MB:-}" in
  ''|*[!0-9]*) echo "!! ABS_MB 非法：'${ABS_MB:-}'（必须为十进制整数）" >&2; exit 2 ;;
esac
if [ "$ABS_MB" -lt 1024 ]; then
  echo "!! ABS_MB=${ABS_MB} 低于硬约束下限 1024，已强制抬回 1024（不得放宽）" >&2
  ABS_MB=1024
fi

PIDFILE="/home/cq/logs/memguard-load-${NAME}.pid"
LOGDIR="/home/cq/logs"
mkdir -p "$LOGDIR"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }

read_mem() { awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null; }
read_psi_full() {
  awk '/^full /{for(i=1;i<=NF;i++) if($i ~ /^avg10=/){sub("avg10=","",$i); print $i; exit}}' \
    /proc/pressure/memory 2>/dev/null || echo 0
}

# ---- S2-4：跨四台协调清场（避免 head 死/worker 活半死态）---------------------
# 设计：先本机保底 kill（绝不因协调器不可用而延后），再尽力调用 /home/cq/v41-kill-all.sh
#       把四台一起清掉。协调器带 flock，重复触发幂等。
COORD="/home/cq/v41-kill-all.sh"
self_is_head() { ip -4 -o addr show 2>/dev/null | grep -q '10\.100\.24\.4'; }

kill_container() {
  local why="$1"
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
      read -r pid _ < "$PIDFILE" || true
      [ -n "${pid:-}" ] && kill "$pid" 2>/dev/null && echo "已停止加载期哨兵 pid=$pid" || echo "哨兵不在运行"
      rm -f "$PIDFILE"
    else
      pkill -f "[v]41-mg-load.sh __watch $NAME" 2>/dev/null && echo "已停止" || echo "哨兵不在运行"
    fi
    exit 0
    ;;

  status)
    if [ -f "$PIDFILE" ]; then
      read -r pid cname < "$PIDFILE" || true
      if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
        echo "加载期哨兵运行中 pid=$pid 容器=${cname:-?}"
        tail -3 "$LOGDIR/memguard-load-${cname:-x}.log" 2>/dev/null || true
      else
        echo "加载期哨兵未运行（stale pidfile）"
      fi
    else
      echo "加载期哨兵未运行"
    fi
    exit 0
    ;;

  start)
    [ -n "$NAME" ] || { echo "需要容器名" >&2; exit 2; }
    if [ -f "$PIDFILE" ] && kill -0 "$(read -r p _ < "$PIDFILE"; echo "$p")" 2>/dev/null; then
      echo "已有加载期哨兵在跑，先 stop"
      exit 2
    fi
    setsid nohup env _ML_LOG="$LOG" _ML_NAME="$NAME" _ML_ABS="$ABS_MB" \
      _ML_INTERVAL="$INTERVAL" _ML_PSI_HARD="$PSI_HARD" _ML_PSI_HARD_ABS="$PSI_HARD_ABS" \
      "$0" __watch "$NAME" > /dev/null 2>&1 < /dev/null &
    sleep 1
    pid=$(pgrep -f "[v]41-mg-load.sh __watch $NAME" | head -1 || true)
    if [ -z "${pid:-}" ]; then
      # S1-1：找不到目标哨兵 ⇒ 绝不谎报成功。清理可能的孤儿并回非零。
      pkill -f "[v]41-mg-load.sh __watch $NAME" 2>/dev/null || true
      rm -f "$PIDFILE"
      echo "!! 加载期哨兵启动失败：未发现 __watch 进程（容器=$NAME）。调用方必须拒绝起服。" >&2
      exit 3
    fi
    printf '%s %s\n' "$pid" "$NAME" > "$PIDFILE"
    echo "加载期哨兵已启动 pid=$pid 容器=$NAME ABS=${ABS_MB}MB 采样=${INTERVAL}s 合取=(avail<${PSI_HARD_ABS}MB AND psi_full>${PSI_HARD})"
    echo "日志：$LOG"
    exit 0
    ;;

  __watch)
    # S3-7：不再 : > "$LOG" 清空日志（避免抹掉上一次触发的证据），改为追加分隔行。
    if [ -f "$LOG" ]; then
      printf '\n[%s] ---- 加载期哨兵重启（保留历史触发证据）----\n' "$(date '+%F %T')" >> "$LOG" 2>/dev/null || true
    fi
    log "加载期哨兵启动：容器=$NAME ABS=${ABS_MB}MB 采样=${INTERVAL}s PSI_HARD=${PSI_HARD} PSI_HARD_ABS=${PSI_HARD_ABS}MB"
    tick=0
    while true; do
      avail=$(read_mem); [ -n "$avail" ] || { sleep "$INTERVAL"; continue; }
      pf=$(read_psi_full)
      tick=$((tick + 1))
      # 每 15 拍（默认 30s）记一次水位，另在 avail 首次跌破 32768MB 后每拍都记（加载进入深水区）
      case "${avail:-0}" in *[!0-9]*) avail=0;; esac
      if [ $((tick % 15)) -eq 0 ] || { [ "$avail" -lt 32768 ] && [ $((tick % 3)) -eq 0 ]; }; then
        log "水位 avail=${avail}MB psi_full=${pf}"
      fi

      fire=""
      if [ "$avail" -lt "$ABS_MB" ]; then
        fire="MemAvailable ${avail}MB < 绝对下限 ${ABS_MB}MB"
      elif [ "$avail" -lt "$PSI_HARD_ABS" ] && awk -v a="$pf" -v b="$PSI_HARD" 'BEGIN{exit !(a+0 > b+0)}'; then
        fire="合取触发：avail ${avail}MB < ${PSI_HARD_ABS}MB 且 PSI full avg10=${pf} > ${PSI_HARD}（真 thrash）"
      fi

      if [ -n "$fire" ]; then
        log "!! 触发：$fire —— 立即杀掉容器 $NAME 以防 wedge"
        log "   触发前水位 avail=${avail}MB psi_full=${pf}"
        kill_container "$fire"
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
    echo "usage: v41-mg-load.sh start <容器名> [ABS_MB] [采样秒] [PSI_HARD] [PSI_HARD_ABS_MB] | stop | status"
    exit 2
    ;;
esac
