#!/usr/bin/env bash
# PM2 里跑 dsh web 的稳定入口：不再每次让 npx 解析 registry。
#
# 背景：PM2 原来用 `npx @deepseek-ai/dsh@latest web`。npm exec 在 registry 解析失败时
# 会直接崩掉，PM2 就一直重启循环（2026-11-15 的 502 就是这么被放大的）。
# 这里按「当前在跑的 npx 缓存 → npm 全局 → npx 兜底」的顺序直连已安装的 bin.js，
# 版本固定为 0.2.2-rc.1（与出事前运行版本一致），升级时改路径即可。
#
# 由 Tools/deploy/pm2-switch.sh 或人工用 PM2 拉起：
#   pm2 start Tools/deploy/dsh-web.sh --name dsh --cwd /home/dywu/.dsh/profiles/web --interpreter bash
set -u

# 与事故前实际运行的 Node 保持一致（v22，避免切大版本带来的原生模块 ABI 差异）。
NODE=/home/dywu/.hermes/node/bin/node
[ -x "$NODE" ] || NODE=/home/dywu/.nvm/versions/node/v24.22.2/bin/node

for BIN in \
  /home/dywu/.npm/_npx/b86ed90107c62dab/node_modules/@deepseek-ai/dsh/lib/bin.js \
  /home/dywu/.nvm/versions/node/v24.22.2/lib/node_modules/@deepseek-ai/dsh/lib/bin.js
do
  if [ -f "$BIN" ]; then
    # 自检模式：只打印版本，不启动服务（部署脚本用它验证 PM2 拉起方式）。
    if [ "${WHALEPET_WRAPPER_TEST:-0}" = "1" ]; then
      exec "$NODE" "$BIN" --version
    fi
    exec "$NODE" "$BIN" web
  fi
done

# 两个本地安装都不见了才退回 npx（不常用，仅防呆）。
exec npx @deepseek-ai/dsh@latest web