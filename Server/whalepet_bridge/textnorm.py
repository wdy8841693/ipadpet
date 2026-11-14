"""Text normalization and wake-phrase matching (pure logic, unit-testable).

No third-party dependencies. Keep this module free of aiohttp / DSH imports
so it can run on any CI machine.
"""
from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field

# 常见的同音/近音误识别（可被环境变量 WHALEPET_WAKE_ALIASES 追加）。
DEFAULT_WAKE_ALIASES: tuple[str, ...] = (
    "小鲸小鲸",
    "小金小金",
    "小精小精",
    "小京小京",
    "小今小今",
    "晓鲸晓鲸",
)

# ASR 结果里常见的中文/英文标点，全部折叠为统一分隔符。
_PUNCT_RE = re.compile(r"[，。！？、；：,.!?;:\s]+")
# Whisper 中文输出可能混入空格；删除汉字之间的空格。
_HAN_SPACE_RE = re.compile(r"(?<=[\u4e00-\u9fff])\s+(?=[\u4e00-\u9fff])")
# 全角转半角前的兼容字符归一。
_SPACE_RE = re.compile(r"\s+")


def normalize(text: str) -> str:
    """Lowercase, strip punctuation and fold whitespace for matching purposes."""
    if not text:
        return ""
    text = unicodedata.normalize("NFKC", text)
    text = text.lower()
    text = _HAN_SPACE_RE.sub("", text)
    text = _PUNCT_RE.sub(" ", text)
    text = _SPACE_RE.sub(" ", text)
    return text.strip()


def _alias_forms(aliases) -> set[str]:
    return {normalize(a) for a in aliases if normalize(a)}


@dataclass
class WakeMatcher:
    """Match the wake phrase at the start of (or alone in) an utterance."""

    wake_phrase: str = "小鲸小鲸"
    aliases: tuple[str, ...] = DEFAULT_WAKE_ALIASES
    # 唤醒词后允许紧跟的分隔符（"小鲸小鲸，帮我…"里的逗号已被 normalize 折叠为空格）。
    separators: tuple[str, ...] = ("，", ",", "。", "！", "！", "?", "？", " ", "：", ":", "、")

    def __post_init__(self) -> None:
        self._forms = _alias_forms((self.wake_phrase, *self.aliases))

    @property
    def forms(self) -> set[str]:
        return set(self._forms)

    def match(self, utterance: str) -> tuple[bool, str]:
        """Return (matched, command).

        ``command`` is the remainder after the wake phrase when the utterance
        both wakes and carries a command in one sentence; empty otherwise.
        """
        norm = normalize(utterance)
        if not norm:
            return False, ""
        for form in sorted(self._forms, key=len, reverse=True):
            if not form:
                continue
            if norm == form:
                # 只说了唤醒词：唤醒成功，命令为空，等待下一句。
                return True, ""
            if norm.startswith(form):
                rest = norm[len(form):].lstrip()
                # 剥掉紧跟的分隔符残留（normalize 后一般是空格，已经 lstrip）。
                rest = rest.lstrip("".join(sorted(set(normalize(s) for s in self.separators))))
                if rest:
                    return True, rest
                return True, ""
        return False, ""


def is_valid_command(text: str, min_len: int = 2) -> bool:
    """过滤空命令与纯标点，防止 VAD 误触发唤醒后立刻查询 DSH。"""
    norm = normalize(text)
    return len(norm) >= min_len


def session_id_ok(session_id) -> bool:
    """限制 session id 形态，避免任意字符串进入 DSH / 文件路径。"""
    if not isinstance(session_id, str):
        return False
    return bool(re.fullmatch(r"[A-Za-z0-9_-]{1,64}", session_id))


@dataclass
class VoiceSessionConfig:
    """Voice pipeline tunables shared by tests and the server."""

    sample_rate: int = 16000
    frame_ms: int = 20
    pre_roll_ms: int = 300
    silence_ms: int = 700
    max_utterance_s: float = 20.0
    listen_timeout_s: float = 10.0

    @property
    def frame_bytes(self) -> int:
        # 16-bit mono PCM
        return int(self.sample_rate * self.frame_ms / 1000) * 2

    @property
    def pre_roll_frames(self) -> int:
        return max(1, self.pre_roll_ms // self.frame_ms)

    @property
    def silence_frames(self) -> int:
        return max(1, self.silence_ms // self.frame_ms)

    @property
    def max_utterance_frames(self) -> int:
        return max(1, int(self.max_utterance_s * 1000 / self.frame_ms))
