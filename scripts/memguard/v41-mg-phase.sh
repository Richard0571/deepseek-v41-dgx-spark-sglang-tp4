#!/usr/bin/env bash
# v41-apikey-20260913: :8001 已启用 --api-key ⇒ curl 自动带 Bearer（自身不设 Authorization 的脚本才需要）
V41_API_KEY_VALUE="$(cat "${V41_API_KEY_FILE:-/home/cq/.v41-apikey}" 2>/dev/null || true)"
if [ -n "$V41_API_KEY_VALUE" ]; then
  curl() { command curl -H "Authorization: Bearer $V41_API_KEY_VALUE" "$@"; }
fi
# v41-mg-phase.sh — 哨兵阶段控制器（在 head 上跑）
#
# 加载期：四台挂 v41-mg-load.sh（杀 = avail<1024  OR  (avail<16384 AND PSI_full>50)）
# 现役终态留 load（2026-09-13 拍板）：start **不**自动切稳态。
#   稳态 psi>5 单腿会误杀（spark-03 当日 00:17 PSI 8.87 / 21:37 PSI 16.09，avail 仍 7–11 GB）。
#   switch 默认拒绝（须 V41_MG_ALLOW_STEADY=1）；V41_MG_AUTO_STEADY=1 仍非默认。
#   四台 memguard.sh v4 已废 PSI 单腿，与 load 同判据；误挂稳态也不会再走 21:37 那条腿。
# 绝对下限 1024 两相位相同，不得放宽。
#
# 2026-09-12 修复（S2-1 / S1-1 / S3-1）：
#   · 旧版 __wait 第一次循环即因「容器尚未创建」而 return 1（调用方在起容器**之前**就 start），
#     故相位切换从装好起从未发生。新版区分：
#       - 容器尚未出现（宽限 30 轮 = 10min）
#       - 容器出现后又消失（连续 6 轮）
#       - ssh 抖动（不计入"不在"）
#   · 切换前加「静默闸」：等 Running+Waiting==0 持续 >=QUIET_HOLD_SEC 秒再切。原因（A 级实测）：
#     加载期/预热期 PSI_full 峰值 28~40，若在预热进行中切到 PSI 5.0 会立刻自杀。
#     ⚠️ 为什么默认 300s（而不是 60s）：当时装载后到长 prefill 之间有约 140s 空窗。
#     60s 静默闸会落在空窗里切到 PSI 5.0，随后长 prefill（PSI 28~40）会打死服务。
#     300s 盖过空窗。已废的自制 boot 不得再当活路径；阈值本身仍按此留。
#     可用 V41_MG_QUIET_SEC 覆盖（演练时可调小以快速观察切换）。
#   · switch_to_steady 逐台校验 memguard 真的在岗，任一失败 → 回非零且不写 steady 状态。
#   · start 逐台校验加载期哨兵真的起岗，任一失败 → 回非零（S1-1 fail-fast，供起服门闩）。
#
# 阈值选择（本节即 S2-1 的"该传什么"决定）：
#   · 绝对下限：一律传 ABS_MB（默认 1024）。这是**硬约束下限，不得放宽**；
#     文档里的 8192 是早期 head 有 16~24 GiB 时的"标准实例"，本配置 head 仅 1.6~5 GiB，
#     挂 8192 会在几秒内误杀（台账 §18.15.2(2)）——故绝不用 8192。
#   · 稳态 PSI 单腿已废（2026-09-13 v4）：memguard.sh 不再用 5.0/60.0 开火。
#     1024 仍是 wedge 底线；PSI 只走合取 avail<16384 AND psi_full>50。
#
# 用法：
#   v41-mg-phase.sh start        # 起加载期哨兵（四台），终态留 load（不自动切稳态）
#   v41-mg-phase.sh switch       # 默认拒绝；须 V41_MG_ALLOW_STEADY=1
#   v41-mg-phase.sh verify-load  # 校验四台加载期哨兵在岗（供起服门闩）
#   v41-mg-phase.sh status
set -uo pipefail

NODES_IP=(10.100.24.4 10.100.24.3 10.100.24.1 10.100.24.2)
HEAD_IP=10.100.24.4
NAME="${V41_NAME:-vllm_dsv41}"
ABS_MB="${V41_MG_MB:-1024}"
INTERVAL="${V41_MG_INTERVAL:-2}"
PSI_HARD="${V41_MG_PSI_HARD:-50.0}"
PSI_HARD_ABS="${V41_MG_PSI_HARD_ABS:-16384}"
STEADY_PSI_FULL="${V41_MG_PSI_FULL:-5.0}"
STEADY_PSI_SOME="${V41_MG_PSI_SOME:-60.0}"
QUIET_HOLD_SEC="${V41_MG_QUIET_SEC:-300}"
PHASEFILE="/home/cq/logs/v41-mg-phase.state"

# S3-1：绝对下限硬钳制
case "${ABS_MB:-}" in
  ''|*[!0-9]*) echo "!! V41_MG_MB 非法：'${ABS_MB:-}'" >&2; exit 2 ;;
esac
if [ "$ABS_MB" -lt 1024 ]; then echo "!! ABS_MB=$ABS_MB < 1024，强制抬回 1024" >&2; ABS_MB=1024; fi

run_on() {  # run_on <ip> <cmd...>
  local ip="$1"; shift
  if [ "$ip" = "$HEAD_IP" ]; then bash -c "$*"; else ssh -n -o BatchMode=yes -o ConnectTimeout=10 "cq@$ip" "$*"; fi
}

start_load_sentinels() {
  echo "=== 起加载期哨兵（四台；先停稳态+加载期，保证互斥）"
  local rc=0 out
  for ip in "${NODES_IP[@]}"; do
    out=$(run_on "$ip" "/home/cq/memguard.sh stop $NAME >/dev/null 2>&1 || true; /home/cq/v41-mg-load.sh stop $NAME >/dev/null 2>&1 || true; /home/cq/v41-mg-load.sh start $NAME $ABS_MB $INTERVAL $PSI_HARD $PSI_HARD_ABS 2>&1")
    printf '%s\n' "$out" | sed "s|^|  $ip |"
    if printf '%s' "$out" | grep -Eq "已启动 pid=[0-9]+"; then :; else
      echo "  !! $ip 加载期哨兵启动失败" >&2; rc=1
    fi
  done
  return $rc
}

verify_load() {
  local rc=0 n
  echo "=== 校验四台加载期哨兵在岗"
  for ip in "${NODES_IP[@]}"; do
    n=$(run_on "$ip" "/home/cq/v41-mg-load.sh status $NAME 2>/dev/null | head -1")
    echo "  $ip  $n"
    case "$n" in *运行中*) : ;; *) rc=1 ;; esac
  done
  return $rc
}

switch_to_steady() {
  case "${V41_MG_ALLOW_STEADY:-0}" in
    1|yes|true|TRUE) ;;
    *)
      echo "!! 拒绝切稳态（2026-09-13：PSI 单腿误杀）。现役留 load。确要切才 export V41_MG_ALLOW_STEADY=1" >&2
      return 2
      ;;
  esac
  echo "=== 切换稳态判据（绝对下限 ${ABS_MB}MB；memguard v4 与 load 同合取，不再用 PSI ${STEADY_PSI_FULL} 单腿）"
  local rc=0 out n
  for ip in "${NODES_IP[@]}"; do
    out=$(run_on "$ip" "/home/cq/v41-mg-load.sh stop $NAME >/dev/null 2>&1 || true; /home/cq/memguard.sh start $NAME $ABS_MB $INTERVAL $STEADY_PSI_FULL $STEADY_PSI_SOME 2>&1")
    printf '%s\n' "$out" | sed "s|^|  $ip |"
    n=$(run_on "$ip" "/home/cq/memguard.sh status $NAME 2>/dev/null | head -1")
    case "$n" in
      *运行中*) : ;;
      *) echo "  !! $ip 稳态哨兵未在岗：$n" >&2; rc=1 ;;
    esac
  done
  # 2026-09-12 S1 修复：写 steady 前必须复核「服务真的在」——
  #   容器在岗且 /v1/models 可达。旧版只校验 memguard.sh status=运行中，
  #   会给已不存在的容器写 steady（16:46:25 那次即如此）。
  if [ "$rc" -eq 0 ]; then
    local nctr
    nctr=$(bash -c "docker ps --format '{{.Names}}' | grep -cx $NAME" 2>/dev/null || echo 0)
    case "${nctr:-}" in ''|*[!0-9]*) nctr=0 ;; esac
    if [ "$nctr" -lt 1 ] || ! service_reachable; then
      echo "  !! 切换校验未过：容器在岗数=${nctr}（需 >=1），/v1/models 不可达或未返回 deepseek —— 拒绝写 steady" >&2
      rc=1
    fi
  fi
  if [ "$rc" -eq 0 ]; then
    echo "steady $(date '+%F %T')" > "$PHASEFILE"
    echo "=== 四台均已切到稳态"
  else
    echo "!! 稳态切换未在四台全部成功，保持 load 状态" >&2
    echo "load-partial $(date '+%F %T')" > "$PHASEFILE"
  fi
  return $rc
}

# 服务可达性判据（S1 修复引入；wait_quiet / switch_to_steady 共用）
service_reachable() {
  curl -s -m 3 "http://$HEAD_IP:8001/v1/models" 2>/dev/null | grep -q "deepseek"
}

# 静默闸：Running+Waiting==0 持续 >=QUIET_HOLD_SEC 秒；>60min 仍不静默则放弃切换（保留加载期判据）
#
# 2026-09-12 S1 修复（fail-safe）：旧版把「取不到 /metrics」当成「0 请求」——
#   curl 失败 ⇒ 管道空输入，但 awk 的 END 块**仍会执行**并打印 `0` ⇒ met="0" ⇒ qs += 20，
#   而代码里为「取不到」准备的 '' 分支**永不命中**。真机实录（A 级）：
#   16:41:21 容器已被加载期哨兵击杀，其孤儿 __wait 仍在 16:46:19 报「服务已静默 >=300s」，
#   给一个**已不存在的容器**切出了 steady。修法两道：
#     (1) 每轮**先**要求 /v1/models 可达（返回含 deepseek）；不可达一律 qs=0，绝不推进；
#     (2) /metrics 必须**至少出现一个** vllm:num_requests_* 前缀才认（awk 置 ok）；
#         否则打印空字符串 ⇒ 落 '' 分支清零。
wait_quiet() {
  local qs=0 qit=0 met raw
  while [ "$qs" -lt "$QUIET_HOLD_SEC" ]; do
    qit=$((qit + 1))
    [ "$qit" -gt 180 ] && return 1
    # (1) 可达性硬闸：服务不可达 ⇒ 视为「非静默」
    if ! service_reachable; then
      qs=0; sleep 20; continue
    fi
    # (2) metrics 必须可解析；空 / 无前缀 ⇒ 打印空 ⇒ 走 '' 分支清零
    raw=$(curl -s -m 4 "http://$HEAD_IP:8001/metrics" 2>/dev/null)
    met=$(printf '%s\n' "$raw" | awk '
      /^vllm:num_requests_running\{/ {r+=$NF; ok=1}
      /^vllm:num_requests_waiting\{/ {w+=$NF; ok=1}
      END {if (ok) printf "%d", r+w}')
    case "${met:-}" in
      ''|*[!0-9]*) qs=0 ;;
      *) [ "$met" -eq 0 ] && qs=$((qs + 20)) || qs=0 ;;
    esac
    [ "$qs" -lt "$QUIET_HOLD_SEC" ] && sleep 20
  done
  return 0
}

wait_ready_then_switch() {
  local log=/home/cq/logs/v41-mg-phase-wait.log
  echo "[$(date '+%F %T')] 等待 http://$HEAD_IP:8001/v1/models 就绪（容器创建宽限 30 轮=10min）……" >> "$log"
  local i absent=0 seen=0 n rc present unknown
  for i in $(seq 1 2160); do   # 2160 * 20s = 12h 上限
    if curl -s -m 3 "http://$HEAD_IP:8001/v1/models" 2>/dev/null | grep -q "deepseek"; then
      echo "[$(date '+%F %T')] /v1/models 已就绪（第 $i 次探测）" >> "$log"
      if wait_quiet; then
        echo "[$(date '+%F %T')] 服务已静默 >=${QUIET_HOLD_SEC}s，切换稳态哨兵" >> "$log"
        if switch_to_steady >> "$log" 2>&1; then
          echo "[$(date '+%F %T')] 切换完成" >> "$log"; return 0
        fi
        echo "[$(date '+%F %T')] 切换失败，30s 后重试" >> "$log"
      else
        echo "[$(date '+%F %T')] 静默闸等待超时（服务持续繁忙 >60min），保持加载期判据，稍后重试" >> "$log"
      fi
      sleep 30
      continue
    fi
    # 判定容器在岗；区分 ssh 抖动与"确认不在"
    present=0; unknown=0
    for ip in "${NODES_IP[@]}"; do
      n=$(run_on "$ip" "docker ps --format '{{.Names}}' | grep -cx $NAME || true" 2>/dev/null); rc=$?
      if [ "$rc" -ne 0 ]; then unknown=1; continue; fi
      case "$n" in ''|*[!0-9]*) unknown=1 ;; *) [ "$n" -ge 1 ] && present=1 ;; esac
    done
    if [ "$present" -eq 1 ]; then
      seen=1; absent=0
    elif [ "$unknown" -eq 1 ]; then
      :  # ssh 抖动：不当作容器不在
    else
      absent=$((absent + 1))
      if [ "$seen" -eq 1 ] && [ "$absent" -ge 6 ]; then
        echo "[$(date '+%F %T')] 容器曾就绪但已连续 ${absent} 轮不在，停止等待" >> "$log"; return 1
      fi
      if [ "$seen" -eq 0 ] && [ "$i" -ge 30 ]; then
        echo "[$(date '+%F %T')] 10 分钟仍未见容器创建，停止等待" >> "$log"; return 1
      fi
    fi
    sleep 20
  done
  echo "[$(date '+%F %T')] 等待超时，放弃切换" >> "$log"
  return 1
}

case "${1:-status}" in
  start)
    pkill -f '[v]41-mg-phase.sh __wait' 2>/dev/null || true
    if start_load_sentinels; then
      case "${V41_MG_AUTO_STEADY:-0}" in
        1|yes|true|TRUE)
          echo "=== V41_MG_AUTO_STEADY=1：挂后台，就绪+静默后仍须 V41_MG_ALLOW_STEADY=1 才会切（非现役默认）"
          setsid nohup "$0" __wait >> /home/cq/logs/v41-mg-phase-wait.log 2>&1 < /dev/null &
          sleep 1
          echo "  等待 job pid=$!"
          ;;
        *)
          echo "=== 留加载期判据（不自动切稳态；switch 默认拒绝，须 V41_MG_ALLOW_STEADY=1）"
          ;;
      esac
      echo "load $(date '+%F %T')" > "$PHASEFILE"
    else
      echo "!! 加载期哨兵未能在四台全部起岗 —— 拒绝进入起服（无哨兵不起服）" >&2
      echo "load-failed $(date '+%F %T')" > "$PHASEFILE"
      exit 1
    fi
    ;;
  verify-load) verify_load ;;
  __wait) wait_ready_then_switch ;;
  switch)
    if switch_to_steady; then exit 0; else exit $?; fi
    ;;
  status)
    echo "=== 阶段：$(cat "$PHASEFILE" 2>/dev/null || echo '未知')"
    for ip in "${NODES_IP[@]}"; do
      echo "--- $ip"
      run_on "$ip" "echo -n 'load: '; /home/cq/v41-mg-load.sh status $NAME | head -1; echo -n 'steady: '; /home/cq/memguard.sh status $NAME | head -1" 2>&1 | sed 's|^|  |'
    done
    ;;
  *)
    echo "usage: v41-mg-phase.sh start|switch|verify-load|status"; exit 2 ;;
esac
