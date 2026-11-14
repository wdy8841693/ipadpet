#!/usr/bin/env python3
"""WhalePet 桥接服务器冒烟测试（不经过 iPad）。

依次验证：
  1. GET /api/health       —— 服务与令牌是否正常
  2. POST /api/chat        —— DSH / API Key / 工作目录是否正常
  3. WS /api/audio + WAV   —— VAD、唤醒词、ASR、整条语音链路

用法：
  export WHALEPET_TOKEN=...        # 与服务器一致
  python scripts/smoke_test.py --url http://127.0.0.1:8787 \
      --wav /tmp/wake.wav [--skip-chat]

WAV 要求：16kHz / mono / 16-bit PCM。macOS 可用：
  say -v Tingting "小鲸小鲸，你好呀" -o /tmp/wake.aiff
  afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/wake.aiff /tmp/wake.wav
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import wave

try:
    import aiohttp
except ImportError:
    aiohttp = None


def load_wav(path: str) -> bytes:
    with wave.open(path, "rb") as w:
        if w.getnchannels() != 1 or w.getsampwidth() != 2:
            raise SystemExit("WAV 必须是 mono / 16-bit PCM")
        if w.getframerate() != 16000:
            raise SystemExit(f"WAV 采样率必须是 16000，当前 {w.getframerate()}")
        return w.readframes(w.getnframes())


async def run(url: str, token: str, wav_path: str | None, skip_chat: bool, timeout: float) -> int:
    if aiohttp is None:
        print("缺少 aiohttp：先 pip install -r requirements.txt", file=sys.stderr)
        return 2
    headers = {"Authorization": f"Bearer {token}"}
    base = url.rstrip("/")

    async with aiohttp.ClientSession(headers=headers) as session:
        # 1) 健康检查
        print("[1/3] 健康检查 ...", end="", flush=True)
        try:
            async with session.get(f"{base}/api/health", timeout=10) as resp:
                body = await resp.text()
                if resp.status != 200:
                    print(f" 失败 HTTP {resp.status}: {body[:200]}")
                    return 1
                print(f" 通过 {body}")
        except Exception as exc:
            print(f" 失败 {exc}")
            return 1

        # 2) 文本聊天（DSH 链路）
        if not skip_chat:
            print("[2/3] DSH 文本聊天 ...", end="", flush=True)
            try:
                payload = {"session_id": "smoke-test", "text": "用一句话介绍你自己。"}
                async with session.post(f"{base}/api/chat", json=payload,
                                        timeout=aiohttp.ClientTimeout(total=timeout)) as resp:
                    body = await resp.text()
                    if resp.status != 200:
                        print(f" 失败 HTTP {resp.status}: {body[:400]}")
                        print("      → 检查 DEEPSEEK_API_KEY / DSH_HOME / 工作目录 / DSH 日志")
                        return 1
                    data = json.loads(body)
                    print(f" 通过 reply={data.get('reply', '')[:80]!r}")
            except Exception as exc:
                print(f" 失败 {exc}")
                return 1
        else:
            print("[2/3] 跳过文本聊天")

        # 3) WebSocket 语音
        print("[3/3] 语音通道（需要 WAV）", end="", flush=True)
        if not wav_path:
            print(" 跳过（未提供 --wav）")
            return 0
        pcm = load_wav(wav_path)
        ws_url = base.replace("http://", "ws://").replace("https://", "wss://") + "/api/audio"
        try:
            async with session.ws_connect(ws_url, timeout=10) as ws:
                print(" 已连接")
                # 先收 ready，再 hello，然后灌音频
                ready = await ws.receive(timeout=10)
                print("     server:", ready.data)
                await ws.send_str(json.dumps({
                    "type": "hello", "session_id": "smoke-test",
                    "wake_phrase": "小鲸小鲸", "sample_rate": 16000,
                }))
                # 20ms 帧 = 640 字节；实时节奏发送，模拟真机。
                for i in range(0, len(pcm), 640):
                    await ws.send_bytes(pcm[i:i + 640])
                    await asyncio.sleep(0.02)
                print(f"     已发送 {len(pcm) / 32000:.1f}s 音频，等待事件 ...")
                deadline = asyncio.get_event_loop().time() + timeout
                saw_response = False
                while asyncio.get_event_loop().time() < deadline:
                    try:
                        msg = await ws.receive(timeout=min(5, timeout))
                    except asyncio.TimeoutError:
                        continue
                    if msg.type == aiohttp.WSMsgType.TEXT:
                        event = json.loads(msg.data)
                        print("     event:", event)
                        if event.get("type") == "response":
                            saw_response = True
                            break
                        if event.get("type") == "error":
                            print("     → 服务端返回错误，见上")
                            return 1
                    elif msg.type in (aiohttp.WSMsgType.CLOSED, aiohttp.WSMsgType.ERROR):
                        print("     连接被关闭")
                        return 1
                if not saw_response:
                    print("     超时：未收到 response。常见原因：WAV 里没有唤醒词、ASR 首次加载模型很慢、音频不是 16k。")
                    return 1
                print("     语音链路通过 ✅")
                return 0
        except Exception as exc:
            print(f" 失败 {exc}")
            return 1


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default=os.environ.get("WHALEPET_URL", "http://127.0.0.1:8787"))
    parser.add_argument("--token", default=os.environ.get("WHALEPET_TOKEN", ""))
    parser.add_argument("--wav", default=None, help="16k/mono/16-bit WAV，内容含“小鲸小鲸”")
    parser.add_argument("--skip-chat", action="store_true", help="只测健康检查与语音")
    parser.add_argument("--timeout", type=float, default=180.0)
    args = parser.parse_args()
    if not args.token:
        print("必须提供 WHALEPET_TOKEN 或 --token", file=sys.stderr)
        raise SystemExit(2)
    code = asyncio.run(run(args.url, args.token, args.wav, args.skip_chat, args.timeout))
    raise SystemExit(code)


if __name__ == "__main__":
    main()
