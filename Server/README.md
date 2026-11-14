# WhalePet 桥接服务器

部署在内网无头服务器上的 aiohttp 服务，把 iPad 宠物的语音/文本请求转发给
DeepSeek Harness（DSH）官方 Python SDK，并完成唤醒词检测与中文语音识别。

```
iPad (WhalePet)  --HTTP/WS-->  本服务  --Python SDK(stdio)-->  dsh --profile sdk  --API--> DeepSeek
        ^                        |
        |                        +-- webrtcvad 切句
        |                        +-- faster-whisper 中文 ASR
        +------ AVSpeechSynthesizer 本地播报（音频不下发）
```

## 安装（Python 3.10+）

```bash
cd Server
python -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
```

## 配置

复制 `.env.example` 逐项填写，最少需要：

| 变量 | 说明 |
|---|---|
| `WHALEPET_TOKEN` | 客户端访问令牌（`python run.py --token` 生成） |
| `DSH_HOME` | DSH 独立 home，**不要**指向 `~/.dsh` |
| `WHALEPET_WORKSPACE` | DSH 工作目录（建议专用空目录，纳入 git） |
| `DEEPSEEK_API_KEY` | DeepSeek API 密钥 |

安全默认：每个新会话先发 `/permission read-only`，DSH 只能读不能写；
如确需让它执行写操作，把 `WHALEPET_DSH_PERMISSION` 设为 `workspace-write`。
DSH 官方自述为开发者预览版且未做安全审计，请保持工作目录可随时丢弃。

## 启动

```bash
python run.py            # 0.0.0.0:8787
# 或
WHALEPET_PORT=9000 python run.py
```

## HTTP / WS 接口

所有请求带 `Authorization: Bearer <WHALEPET_TOKEN>`。

- `GET /api/health` → `{"ok":true,"asr":bool,"model":"..."}`
- `POST /api/chat` `{"session_id":"pet-001","text":"..."}` → `{"ok":true,"reply":"..."}`
- `WS /api/audio` 语音通道：
  - 首条文本 `{"type":"hello","session_id":"pet-001","wake_phrase":"小鲸小鲸","sample_rate":16000}`
  - 控制消息（纯文本）：`manual_start` / `cancel` / `playback_start` / `playback_end`
  - 其余二进制帧 = 16kHz / mono / little-endian Int16 PCM
  - 服务端事件（JSON 文本）：
    `ready` / `state(waiting|listening|thinking|speaking)` / `wake` /
    `transcript{text}` / `thinking` / `response{text}` / `error{message}`

## 语音流程

1. 等待态：VAD 切出的每段语音经 faster-whisper 识别，规范化后匹配
   "小鲸小鲸"（含可配置同音别名）。只说唤醒词 → 进入聆听；一句话带命令 → 直接执行。
2. 聆听态：下一段有效语音即命令；`listen_timeout_s`（默认 10s）无命令回到等待。
3. 命令 → DSH 执行 → `response` 返回文本，iPad 端本地 TTS 播报。
4. 客户端播报期间发 `playback_start` / `playback_end`，服务端暂停拾音，防止宠物自触发。

## 测试

```bash
python -m unittest discover -s tests    # 纯逻辑：唤醒匹配 / 状态机 / 配置
```

（ASR 与 DSH 依赖外部模型/密钥，不在单测范围；部署后用 iPad 真机联调。）

## 分层调试（推荐顺序）

不要一上来就用 iPad 测。按下面四层逐级排查，哪层失败就停在哪层。

### 第 1 层：服务能起来

```bash
python run.py --token                    # 生成一个令牌，填进 .env
python run.py                            # 前台启动，观察日志
```

另开终端：

```bash
curl -H "Authorization: Bearer $WHALEPET_TOKEN" http://127.0.0.1:8787/api/health
```

期望 `{"ok": true, "asr": false, "model": "..."}`。  
401 = 令牌不一致；连不上 = 端口/HOST 配置或进程未启动。

### 第 2 层：DSH 能回答（不含语音）

```bash
curl -s -H "Authorization: Bearer $WHALEPET_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"session_id":"debug-1","text":"只回复：你好"}' \
  http://127.0.0.1:8787/api/chat
```

期望 `{"ok":true,"reply":"你好"}`。失败时看返回的 error：

| 错误关键字 | 检查点 |
|---|---|
| `deepseek-harness-sdk 未安装` | `pip install -r requirements.txt` |
| `启动 DSH runtime 失败` | `DSH_HOME` 是否存在且可写；`DSH_PROFILE=sdk` 是否可用 |
| `DSH 执行失败` | `DEEPSEEK_API_KEY` 是否有效、网络能否访问 DeepSeek |
| `DSH 没有返回文本回复` | 查看 DSH 自己的日志；先用 CLI 跑通同一 home |

### 第 3 层：语音链路（不经过 iPad）

```bash
# macOS 生成一段含唤醒词的中文测试音频
say -v Tingting "小鲸小鲸，你好呀" -o /tmp/wake.aiff
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/wake.aiff /tmp/wake.wav

python scripts/smoke_test.py --wav /tmp/wake.wav
```

脚本依次测 health / chat / WS 语音，并打印服务端事件：

```
ready → wake → state(listening) → transcript("你好呀") → thinking → response("...")
```

常见问题：

- **首次很慢**：faster-whisper 第一次会下载 small 模型（数百 MB），耐心等或预先跑一次。
- **没有 ready**：WS 鉴权失败（401），检查同一个 `WHALEPET_TOKEN`。
- **有 ready 无 wake**：检查 WAV 是否 16k/mono/16-bit、内容是否真的说了唤醒词；
  中文识别对同音字宽容度有限，可用 `WHALEPET_WAKE_ALIASES=小金小金,...` 追加别名。
- **有 wake 无 response**：回到第 2 层，DSH 本身有问题。

### 第 4 层：iPad 联调

1. iPad 与服务器同一 Wi-Fi/网段，`ping` 服务器 IP。
2. 首次进 App ⚙️ 填 `http://服务器IP:8787` 和令牌，保存时会立即请求 health；
   系统会弹 **本地网络** 与 **麦克风** 权限，都要允许。
3. 点 🎙️ 手动触发（绕过唤醒词）先验证"采集→ASR→DSH→播报"整链；
   手动成功但"小鲸小鲸"不灵，只需调唤醒词/ASR，不用查网络。
4. Xcode 调试时看控制台：
   - `WhalePet: 音频转换失败 ...` → 麦克风格式异常
   - HTTP 401 → 令牌不对
   - `语音通道断开` → Wi-Fi 抖动、服务器重启或 token 失效
5. 若报 ATS/明文 HTTP 错误：优先给服务器配 HTTPS（`WHALEPET_TLS_CERT/KEY`）
   或用 `.local` 主机名；不要为了调试长期打开 `NSAllowsArbitraryLoads`。

### iPad 端表现对照

| 宠物/胶囊状态 | 含义 | 下一步 |
|---|---|---|
| 正在连接服务器… | health 检查中 | 查地址/网段/令牌 |
| 待唤醒（说"小鲸小鲸"） | WS 已连、正在采集 | 说唤醒词或点 🎙️ |
| 在听，请说指令… | 已唤醒，10s 内说命令 | 直接说指令 |
| 思考中… | 已送 DSH | 等；超时看服务端日志 |
| 回答中… | TTS 播报 | 播报结束自动回等待 |
| 语音异常：… | 具体错误在气泡/胶囊 | 按错误文案回查上面四层 |

## systemd 示例

```ini
[Unit]
Description=WhalePet bridge
After=network-online.target

[Service]
WorkingDirectory=/opt/whalepet/Server
EnvironmentFile=/opt/whalepet/Server/.env
ExecStart=/opt/whalepet/Server/.venv/bin/python run.py
Restart=on-failure
User=whalepet

[Install]
WantedBy=multi-user.target
```
