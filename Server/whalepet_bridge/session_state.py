"""Voice session state machine (pure logic, unit-testable).

States:
    waiting   -- 前台监听唤醒词
    listening -- 已唤醒（或手动触发），正在收集命令
"""
from __future__ import annotations

import enum
from typing import Optional

from .textnorm import VoiceSessionConfig, WakeMatcher, is_valid_command


class VoicePhase(str, enum.Enum):
    WAITING = "waiting"
    LISTENING = "listening"


class WakeOutcome(str, enum.Enum):
    NONE = "none"                       # 不是唤醒语句
    WAKE_ONLY = "wake_only"             # 只说了唤醒词，等待命令
    WAKE_WITH_COMMAND = "wake_command"  # 一句话带命令


class VoiceSession:
    """Track one client's wake/command phase. Independent of transports."""

    def __init__(
        self,
        matcher: Optional[WakeMatcher] = None,
        config: Optional[VoiceSessionConfig] = None,
    ) -> None:
        self.matcher = matcher or WakeMatcher()
        self.config = config or VoiceSessionConfig()
        self.phase = VoicePhase.WAITING

    @classmethod
    def from_config(cls, bridge_config) -> "VoiceSession":
        """Build from a BridgeConfig (uses its wake phrase/aliases/voice)."""
        matcher = WakeMatcher(
            wake_phrase=bridge_config.wake_phrase,
            aliases=bridge_config.wake_aliases,
        )
        return cls(matcher=matcher, config=bridge_config.voice)

    # -- wake matching ---------------------------------------------------

    def classify(self, utterance: str) -> tuple[WakeOutcome, str]:
        matched, command = self.matcher.match(utterance)
        if not matched:
            return WakeOutcome.NONE, ""
        if is_valid_command(command):
            return WakeOutcome.WAKE_WITH_COMMAND, command
        return WakeOutcome.WAKE_ONLY, ""

    def feed_waiting(self, utterance: str) -> tuple[WakeOutcome, str]:
        """Waiting phase: returns outcome and advances phase on wake."""
        outcome, command = self.classify(utterance)
        if outcome is WakeOutcome.WAKE_ONLY:
            self.phase = VoicePhase.LISTENING
        elif outcome is WakeOutcome.WAKE_WITH_COMMAND:
            # 一句话带命令：直接交付命令，不进入 listening。
            self.phase = VoicePhase.WAITING
        return outcome, command

    def feed_listening(self, utterance: str) -> tuple[bool, str]:
        """Listening phase: any valid utterance is a command."""
        if is_valid_command(utterance):
            self.phase = VoicePhase.WAITING
            return True, utterance
        return False, ""

    def manual_start(self) -> None:
        self.phase = VoicePhase.LISTENING

    def reset(self) -> None:
        self.phase = VoicePhase.WAITING

    # -- VAD frame bookkeeping --------------------------------------------

    def vad_should_emit(
        self,
        voiced_frames: int,
        silence_run: int,
        total_frames: int,
    ) -> bool:
        """An utterance ends on `silence_run` silent frames after speech,
        or when it hits the hard cap."""
        if voiced_frames == 0:
            return False
        return (
            total_frames >= self.config.max_utterance_frames
            or silence_run >= self.config.silence_frames
        )
