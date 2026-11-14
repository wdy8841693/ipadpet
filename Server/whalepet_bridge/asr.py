"""Lazy faster-whisper ASR wrapper.

The model loads on first use so the server can boot (and health checks can
answer) without the model resident. All transcription is CPU/GPU bound and
must be called from a worker thread (the server uses asyncio.to_thread).
"""
from __future__ import annotations

import io
import logging
import threading
import wave
from typing import Optional

import numpy as np

from .config import BridgeConfig

logger = logging.getLogger("whalepet.asr")


class ASRError(RuntimeError):
    pass


class Transcript:
    def __init__(self, text: str) -> None:
        self.text = text


class LazyWhisperASR:
    """faster-whisper with lazy init and a load lock."""

    def __init__(self, config: BridgeConfig) -> None:
        self._config = config
        self._lock = threading.Lock()
        self._model = None
        self._load_error: Optional[str] = None

    @property
    def loaded(self) -> bool:
        return self._model is not None

    def _ensure_model(self):
        with self._lock:
            if self._model is not None:
                return self._model
            if self._load_error is not None:
                # 先前加载失败：不无限重试大模型下载，直接复述错误。
                raise ASRError(self._load_error)
            try:
                from faster_whisper import WhisperModel  # type: ignore
            except Exception as exc:  # pragma: no cover - depends on env
                self._load_error = f"faster-whisper 未安装: {exc}"
                raise ASRError(self._load_error) from exc
            try:
                self._model = WhisperModel(
                    self._config.asr_model,
                    device=self._config.asr_device,
                    compute_type=self._config.asr_compute_type,
                )
                logger.info(
                    "ASR model loaded: %s (%s/%s)",
                    self._config.asr_model,
                    self._config.asr_device,
                    self._config.asr_compute_type,
                )
            except Exception as exc:
                self._load_error = f"加载 ASR 模型失败: {exc}"
                raise ASRError(self._load_error) from exc
            return self._model

    def transcribe_pcm16(self, pcm: bytes, sample_rate: int = 16000) -> Transcript:
        """Transcribe raw 16-bit mono PCM. Blocking; call in a thread."""
        if not pcm:
            return Transcript("")
        model = self._ensure_model()
        audio = np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0
        if sample_rate != 16000:
            raise ASRError(f"仅支持 16kHz 音频，收到 {sample_rate}Hz")
        try:
            segments, _info = model.transcribe(
                audio,
                language="zh",
                beam_size=1,
                vad_filter=False,  # 我们在外层已有 webrtcvad 切分
                condition_on_previous_text=False,
            )
            text = "".join(seg.text for seg in segments).strip()
        except ASRError:
            raise
        except Exception as exc:
            raise ASRError(f"识别失败: {exc}") from exc
        return Transcript(text)


def pcm16_to_wav_bytes(pcm: bytes, sample_rate: int = 16000) -> bytes:
    """Helper kept for debugging/dumping utterances."""
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sample_rate)
        w.writeframes(pcm)
    return buf.getvalue()
