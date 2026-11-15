#!/usr/bin/env bash
# 延迟重启 PM2 里的 dsh：给当前会话留时间把回复说完，再重启让插件加载最新磁盘代码。
#
# 用法（在仓库根目录）：
#   DSH_RELOAD_DELAY=40 pm2 start Tools/deploy/reload-dsh.sh \
#     --name dsh-reload --interpreter bash --no-autorestart
# 日志：Tools/deploy/reload-dsh.log
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$SCRIPT_DIR/reload-dsh.log"
exec >>"$LOG" 2>&1

PM2=$(command -v pm2)

health() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:3080/ 2>/dev/null || true
}

echo "=== $(date -Is) reload scheduled (pid $$), delay=${DSH_RELOAD_DELAY:-25}s"
sleep "${DSH_RELOAD_DELAY:-25}"

echo "--- $(date -Is) pm2 restart dsh"
"$PM2" restart dsh >/dev/null 2>&1

ok=0
for i in $(seq 1 40); do
  code=$(health)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then
    ok=1
    break
  fi
  sleep 1
done
if [ "$ok" = "1" ]; then
  echo "--- $(date -Is) dsh healthy after ${i}s (HTTP $code)"
else
  echo "--- $(date -Is) dsh NOT healthy after 40s (last HTTP $code)，请手工 pm2 logs dsh"
fi
echo "=== $(date -Is) done"
"$PM2" delete dsh-reload >/dev/null 2>&1