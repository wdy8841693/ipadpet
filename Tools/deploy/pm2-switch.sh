#!/usr/bin/env bash
# 把 PM2 里的 dsh 从 `npx @deepseek-ai/dsh@latest web` 换成直连本地安装的 dsh。
#
# 做法：本脚本作为独立的 PM2 应用（dsh-switch）运行——它挂在 pm2 daemon 下面，
# 不受当前 dsh 进程死活影响。等待若干秒（默认 25s，让当前会话把话说完后），
# 删除旧 dsh 应用 → 用 Tools/deploy/dsh-web.sh 重启 → 健康检查 → pm2 save；
# 若新进程 40s 内起不来，自动回退到旧命令，避免把 GUI 弄丢。
#
# 日志：Tools/deploy/pm2-switch.log
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$SCRIPT_DIR/pm2-switch.log"
exec >>"$LOG" 2>&1

PM2=$(command -v pm2)
WRAPPER="$SCRIPT_DIR/dsh-web.sh"
CWD="${DSH_PROFILE_DIR:-$HOME/.dsh/profiles/web}"

health() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:3080/ 2>/dev/null || true
}

echo "=== $(date -Is) dsh-switch start (pid $$), delay=${DSH_SWITCH_DELAY:-25}s"
sleep "${DSH_SWITCH_DELAY:-25}"

echo "--- $(date -Is) stopping old app"
"$PM2" delete dsh >/dev/null 2>&1
sleep 2

echo "--- $(date -Is) starting direct-binary wrapper"
"$PM2" start "$WRAPPER" --name dsh --cwd "$CWD" --interpreter bash >/dev/null 2>&1

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
  echo "--- $(date -Is) new dsh healthy after ${i}s (HTTP $code)"
  "$PM2" save >/dev/null 2>&1
  echo "--- $(date -Is) saved pm2 process list"
else
  echo "--- $(date -Is) new dsh FAILED, falling back to npx"
  "$PM2" delete dsh >/dev/null 2>&1
  "$PM2" start /usr/bin/bash --name dsh --cwd "$CWD" -- -c 'npx @deepseek-ai/dsh@latest web' >/dev/null 2>&1
  sleep 12
  echo "--- $(date -Is) fallback health: $(health)"
  "$PM2" save >/dev/null 2>&1
fi

echo "=== $(date -Is) done"
"$PM2" delete dsh-switch >/dev/null 2>&1