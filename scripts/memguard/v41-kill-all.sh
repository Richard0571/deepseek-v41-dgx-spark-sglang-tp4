#!/usr/bin/env bash
# v41-kill-all.sh — 四台统一清场（S2-4：避免 TP4「head 死 / worker 活」半死态）
#
# 背景：加载期/稳定期哨兵触发时若只 `docker kill` 本机，TP4 其余三台容器仍在，
#       形成半死态，需人工清场（台账 §18.15.1）。本脚本把清场收敛为一个带锁动作。
#
# 由内存哨兵在触发时尽力调用（本机先保底 kill，再调本脚本清四台）。
# flock 保证重复触发幂等；任一节点 SSH 失败会回非零但其它节点仍清。
#
# 用法：v41-kill-all.sh [容器名=vllm_dsv41] [--dry-run]
# 退出码：0 全部清掉；1 有节点失败
set -uo pipefail
NAME="${1:-vllm_dsv41}"
DRY=0
[ "${2:-}" = "--dry-run" ] && DRY=1
NODES="10.100.24.4 10.100.24.3 10.100.24.1 10.100.24.2"
HEAD=10.100.24.4
LOCK=/tmp/v41-kill-all.lock

exec 9>"$LOCK" || { echo "无法创建锁 $LOCK"; exit 1; }
if ! flock -n 9; then echo "另一清场进行中，本次跳过（幂等）"; exit 0; fi

echo "[$(date '+%F %T')] kill-all 容器=$NAME dry=$DRY"
rc=0
for ip in $NODES; do
  if [ "$ip" = "$HEAD" ]; then
    if [ "$DRY" = 1 ]; then
      echo "  $ip (head/local) 将执行 docker kill+rm $NAME"
    else
      docker kill "$NAME" >/dev/null 2>&1 || true
      sleep 1
      docker rm -f "$NAME" >/dev/null 2>&1 || true
      echo "  $ip (head/local) 已清"
    fi
  else
    if [ "$DRY" = 1 ]; then
      echo "  $ip (ssh) 将执行 docker kill+rm $NAME"
    else
      if ssh -n -o BatchMode=yes -o ConnectTimeout=5 "cq@$ip" \
           "docker kill $NAME >/dev/null 2>&1 || true; sleep 1; docker rm -f $NAME >/dev/null 2>&1 || true; echo ok" 2>/dev/null | grep -q ok; then
        echo "  $ip 已清"
      else
        echo "  $ip 清场失败（SSH 不通？）"
        rc=1
      fi
    fi
  fi
done
echo "[$(date '+%F %T')] kill-all 结束 rc=$rc"
exit $rc
