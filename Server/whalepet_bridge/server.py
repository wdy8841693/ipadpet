"""aiohttp server: HTTP health/chat + WebSocket voice pipeline.

Protocol (see Server/README.md):
- GET  /api/health        -> {"ok": true, "asr": bool}
- POST /api/chat          -> {"session_id","text"} -> {"reply"}
- WS   /api/audio         -> hello / manual_start / cancel / playback_start /
                             playback_end (text JSON), binary = 16k mono PCM.
Server -> client events: ready / state / wake / transcript / thinking /
response / error (all JSON text).
"""
from __future__ import annotations

import asyncio
import hmac
import json
import logging
from typing import Optional

from aiohttp import WSMsgType, web

from .asr import ASRError, LazyWhisperASR
from .config import BridgeConfig
from .dsh import DSHError, DSHRunner
from .session_state import VoicePhase, VoiceSession, WakeOutcome
from .textnorm import session_id_ok

logger = logging.getLogger("whalepet.server")

MAX_WS_MESSAGE = 512 * 1024  # 单条消息上限，防滥用


def json_error(message: str, status: int = 400) -> web.Response:
    return web.json_response({"ok": False, "error": message}, status=status)


class BridgeApp:
    def __init__(self, config: BridgeConfig) -> None:
        self.config = config
        self.asr = LazyWhisperASR(config)
        self.dsh = DSHRunner(config)
        self._dsh_task: Optional[asyncio.Task] = None
        self._dsh_lock = asyncio.Lock()

    # -- auth ------------------------------------------------------------

    def _check_token(self, request: web.Request) -> bool:
        header = request.headers.get("Authorization", "")
        if not header.startswith("Bearer "):
            return False
        supplied = header[len("Bearer "):].strip()
        expected = self.config.token
        # 常数时间比较，避免时序侧信道（encode 成 bytes 以兼容非 ASCII 输入）。
        return hmac.compare_digest(supplied.encode(), expected.encode())

    # -- HTTP --------------------------------------------------------------

    async def health(self, request: web.Request) -> web.Response:
        if not self._check_token(request):
            return json_error("未授权", 401)
        return web.json_response(
            {"ok": True, "asr": self.asr.loaded, "model": self.config.model}
        )

    async def chat(self, request: web.Request) -> web.Response:
        if not self._check_token(request):
            return json_error("未授权", 401)
        try:
            body = await request.json()
        except Exception:
            return json_error("请求体不是合法 JSON")
        session_id = body.get("session_id")
        text = body.get("text")
        if not session_id_ok(session_id):
            return json_error("session_id 不合法")
        if not isinstance(text, str) or not text.strip():
            return json_error("text 不能为空")
        try:
            reply = await asyncio.wait_for(
                asyncio.to_thread(self.dsh.ask, session_id, text.strip()),
                timeout=self.config.dsh_request_timeout_s,
            )
        except asyncio.TimeoutError:
            return json_error("DSH 响应超时", 504)
        except DSHError as exc:
            return json_error(str(exc), 502)
        return web.json_response({"ok": True, "reply": reply})

    # -- WebSocket voice -----------------------------------------------------

    async def audio_ws(self, request: web.Request) -> web.WebSocketResponse:
        if not self._check_token(request):
            raise web.HTTPUnauthorized(text="未授权")
        ws = web.WebSocketResponse(max_msg_size=MAX_WS_MESSAGE, heartbeat=30)
        await ws.prepare(request)

        session = VoiceSession.from_config(self.config)
        pipeline = VoicePipeline(self, session, ws)
        try:
            await pipeline.run()
        finally:
            await pipeline.shutdown()
        return ws


class VoicePipeline:
    """Per-connection audio pipeline: VAD -> ASR -> wake/command -> DSH."""

    def __init__(self, app: BridgeApp, session: VoiceSession, ws) -> None:
        self.app = app
        self.config = app.config
        self.session = session
        self.ws = ws
        self.frame_bytes = self.config.voice.frame_bytes
        self.vad = None
        self._init_vad()
        # 采集缓冲
        self.buffer = bytearray()          # 未成帧的 PCM 残片
        self.pre_roll = bytearray()        # 静音期的 pre-roll 环形保留
        self.utterance: Optional[bytearray] = None  # 当前语音段
        self.voiced_frames = 0
        self.silence_run = 0
        self.total_frames = 0
        self.capture_paused = False
        self.listen_deadline: Optional[asyncio.TimerHandle] = None
        self.closed = False
        self.session_id: Optional[str] = None

    def _init_vad(self) -> None:
        try:
            import webrtcvad  # type: ignore

            self.vad = webrtcvad.Vad(2)
        except Exception as exc:  # pragma: no cover
            logger.error("webrtcvad 初始化失败: %s", exc)

    async def send(self, payload: dict) -> None:
        if self.closed:
            return
        try:
            await self.ws.send_str(json.dumps(payload, ensure_ascii=False))
        except Exception:
            self.closed = True

    async def run(self) -> None:
        ready = {"ok": True, "type": "ready",
                 "wake_phrase": self.config.wake_phrase,
                 "sample_rate": self.config.voice.sample_rate}
        await self.send(ready)

        async for msg in self.ws:
            if msg.type == WSMsgType.TEXT:
                await self.handle_control(msg.data)
            elif msg.type == WSMsgType.BINARY:
                self.feed_audio(msg.data)
            elif msg.type in (WSMsgType.ERROR, WSMsgType.CLOSE, WSMsgType.CLOSING):
                break

    # -- control ------------------------------------------------------------

    async def handle_control(self, raw: str) -> None:
        # 协议里既有纯命令字符串，也预留 JSON 扩展。
        text = raw.strip()
        if text == "manual_start":
            self.session.manual_start()
            self.reset_vad()
            await self.send({"type": "state", "value": "listening"})
            self.arm_listen_timeout()
            return
        if text == "cancel":
            await self.cancel_pending()
            self.session.reset()
            self.reset_vad()
            await self.send({"type": "state", "value": "waiting"})
            return
        if text == "playback_start":
            # 宠物开始播报：暂停采集，避免拾到自己的声音。
            self.capture_paused = True
            self.reset_vad()
            return
        if text == "playback_end":
            self.capture_paused = False
            self.reset_vad()
            self.session.reset()
            await self.send({"type": "state", "value": "waiting"})
            return
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            await self.send({"type": "error", "message": "无法解析的控制消息"})
            return
        if isinstance(data, dict) and data.get("type") == "hello":
            sid = data.get("session_id")
            if not session_id_ok(sid):
                await self.send({"type": "error", "message": "session_id 不合法"})
                await self.ws.close()
                return
            self.session_id = sid
            await self.dsh_permission_once(sid)
            return
        await self.send({"type": "error", "message": "未知控制消息"})

    async def dsh_permission_once(self, session_id: str) -> None:
        try:
            await asyncio.to_thread(self.app.dsh.apply_permission, session_id)
        except Exception as exc:  # pragma: no cover
            logger.warning("权限预设发送失败: %s", exc)

    async def cancel_pending(self) -> None:
        task = self.app._dsh_task
        if task and not task.done():
            task.cancel()
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass
        self.app._dsh_task = None

    # -- audio --------------------------------------------------------------

    def reset_vad(self) -> None:
        self.buffer.clear()
        self.pre_roll.clear()
        self.utterance = None
        self.voiced_frames = 0
        self.silence_run = 0
        self.total_frames = 0

    def feed_audio(self, data: bytes) -> None:
        if self.capture_paused or self.vad is None:
            return
        # 按固定 20ms 帧切分（客户端保证每包是帧的整数倍，这里再兜底拼接）。
        self.buffer.extend(data)
        while len(self.buffer) >= self.frame_bytes:
            frame = bytes(self.buffer[: self.frame_bytes])
            del self.buffer[: self.frame_bytes]
            self.process_frame(frame)

    def process_frame(self, frame: bytes) -> None:
        try:
            voiced = self.vad.is_speech(frame, self.config.voice.sample_rate)
        except Exception:
            voiced = False
        self.total_frames += 1

        if voiced:
            if self.utterance is None:
                # 语音开始：带上 pre-roll，让 ASR 听到起始辅音。
                self.utterance = bytearray(self.pre_roll)
                self.voiced_frames = 0
                self.silence_run = 0
            self.voiced_frames += 1
            self.silence_run = 0
            self.utterance.extend(frame)
        else:
            # 静音期保留 pre-roll。
            self.pre_roll.extend(frame)
            excess = len(self.pre_roll) - self.frame_bytes * self.config.voice.pre_roll_frames
            if excess > 0:
                del self.pre_roll[:excess]
            if self.utterance is not None:
                # 尾部静音也计入语音段，判停由 silence_run 决定。
                self.utterance.extend(frame)
                self.silence_run += 1

        if self.session.vad_should_emit(
            self.voiced_frames, self.silence_run, self.total_frames
        ):
            utterance = self.utterance or bytearray()
            self.reset_vad()
            if utterance:
                # 交给事件循环处理（feed_audio 在接收循环里同步调用）。
                asyncio.ensure_future(self.handle_utterance(bytes(utterance)))

    # -- utterance handling ---------------------------------------------------

    async def handle_utterance(self, pcm: bytes) -> None:
        if self.closed:
            return
        try:
            text = await asyncio.to_thread(self.app.asr.transcribe_pcm16, pcm)
        except ASRError as exc:
            await self.send({"type": "error", "message": str(exc)})
            return
        utterance = text.text.strip()
        if not utterance:
            return
        if self.session.phase is VoicePhase.WAITING:
            outcome, command = self.session.feed_waiting(utterance)
            if outcome is WakeOutcome.NONE:
                return  # 普通环境人声，忽略。
            await self.send({"type": "wake", "phrase": utterance})
            if outcome is WakeOutcome.WAKE_WITH_COMMAND:
                await self.dispatch_command(command)
            else:
                await self.send({"type": "state", "value": "listening"})
                self.arm_listen_timeout()
        else:
            ok, command = self.session.feed_listening(utterance)
            if ok:
                self.disarm_listen_timeout()
                await self.dispatch_command(command)
            # 无效命令（太短/纯标点）继续等待，不额外提示。

    def arm_listen_timeout(self) -> None:
        self.disarm_listen_timeout()
        loop = asyncio.get_event_loop()
        self.listen_deadline = loop.call_later(
            self.config.voice.listen_timeout_s,
            lambda: asyncio.ensure_future(self.on_listen_timeout()),
        )

    def disarm_listen_timeout(self) -> None:
        if self.listen_deadline is not None:
            self.listen_deadline.cancel()
            self.listen_deadline = None

    async def on_listen_timeout(self) -> None:
        if self.session.phase is VoicePhase.LISTENING:
            self.session.reset()
            await self.send({"type": "state", "value": "waiting"})

    async def dispatch_command(self, command: str) -> None:
        await self.send({"type": "transcript", "text": command})
        await self.send({"type": "state", "value": "thinking"})
        sid = getattr(self, "session_id", None)
        if not sid:
            await self.send({"type": "error", "message": "尚未完成 hello 握手"})
            return

        async def run_dsh() -> None:
            try:
                reply = await asyncio.wait_for(
                    asyncio.to_thread(self.app.dsh.ask, sid, command),
                    timeout=self.config.dsh_request_timeout_s,
                )
            except asyncio.CancelledError:
                raise
            except asyncio.TimeoutError:
                await self.send({"type": "error", "message": "DSH 响应超时"})
                return
            except DSHError as exc:
                await self.send({"type": "error", "message": str(exc)})
                return
            except Exception as exc:  # pragma: no cover
                await self.send({"type": "error", "message": f"内部错误: {exc}"})
                return
            await self.send({"type": "response", "text": reply})

        async with self.app._dsh_lock:
            await self.cancel_pending()
            self.app._dsh_task = asyncio.create_task(run_dsh())
            try:
                await self.app._dsh_task
            except asyncio.CancelledError:
                await self.send({"type": "state", "value": "waiting"})
            finally:
                self.app._dsh_task = None

    async def shutdown(self) -> None:
        self.closed = True
        self.disarm_listen_timeout()
        await self.cancel_pending()


def build_app(config: BridgeConfig) -> web.Application:
    bridge = BridgeApp(config)
    app = web.Application()
    app["bridge"] = bridge
    app.router.add_get("/api/health", bridge.health)
    app.router.add_post("/api/chat", bridge.chat)
    app.router.add_get("/api/audio", bridge.audio_ws)
    return app


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )
    config = BridgeConfig.from_env()
    problems = config.validate()
    if problems:
        for p in problems:
            logger.error("配置错误: %s", p)
        raise SystemExit(2)
    app = build_app(config)
    ssl_context = None
    if config.tls_cert and config.tls_key:
        import ssl

        ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ssl_context.load_cert_chain(config.tls_cert, config.tls_key)
    logger.info(
        "WhalePet bridge listening on %s:%s (tls=%s)",
        config.host, config.port, bool(ssl_context),
    )
    # 打印地址但不打印 token。
    web.run_app(app, host=config.host, port=config.port, ssl_context=ssl_context)


if __name__ == "__main__":
    main()
