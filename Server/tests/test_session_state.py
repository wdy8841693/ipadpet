"""Pure-logic tests for the voice session state machine."""
from __future__ import annotations

import unittest

from whalepet_bridge.session_state import (
    VoicePhase,
    VoiceSession,
    WakeOutcome,
)
from whalepet_bridge.textnorm import VoiceSessionConfig


class TestVoiceSession(unittest.TestCase):
    def setUp(self):
        self.s = VoiceSession(config=VoiceSessionConfig())

    def test_wake_only_transitions_to_listening(self):
        outcome, cmd = self.s.feed_waiting("小鲸小鲸")
        self.assertIs(outcome, WakeOutcome.WAKE_ONLY)
        self.assertEqual(cmd, "")
        self.assertIs(self.s.phase, VoicePhase.LISTENING)

    def test_wake_with_command_skips_listening(self):
        outcome, cmd = self.s.feed_waiting("小鲸小鲸，今天几号")
        self.assertIs(outcome, WakeOutcome.WAKE_WITH_COMMAND)
        self.assertEqual(cmd, "今天几号")
        self.assertIs(self.s.phase, VoicePhase.WAITING)

    def test_idle_speech_ignored(self):
        outcome, _ = self.s.feed_waiting("电视里在放新闻")
        self.assertIs(outcome, WakeOutcome.NONE)
        self.assertIs(self.s.phase, VoicePhase.WAITING)

    def test_listening_accepts_command(self):
        self.s.manual_start()
        ok, cmd = self.s.feed_listening("帮我设个十分钟的计时器")
        self.assertTrue(ok)
        self.assertEqual(cmd, "帮我设个十分钟的计时器")
        self.assertIs(self.s.phase, VoicePhase.WAITING)

    def test_listening_rejects_noise(self):
        self.s.manual_start()
        ok, _ = self.s.feed_listening("嗯")
        self.assertFalse(ok)
        self.assertIs(self.s.phase, VoicePhase.LISTENING)

    def test_manual_start(self):
        self.s.manual_start()
        self.assertIs(self.s.phase, VoicePhase.LISTENING)

    def test_reset(self):
        self.s.manual_start()
        self.s.reset()
        self.assertIs(self.s.phase, VoicePhase.WAITING)

    def test_vad_emit_on_silence(self):
        c = VoiceSessionConfig(silence_ms=700, frame_ms=20, max_utterance_s=20)
        s = VoiceSession(config=c)
        self.assertFalse(s.vad_should_emit(0, 35, 100))   # 没有语音
        self.assertFalse(s.vad_should_emit(10, 34, 50))
        self.assertTrue(s.vad_should_emit(10, 35, 60))    # 静音判停

    def test_vad_emit_on_cap(self):
        c = VoiceSessionConfig(frame_ms=20, max_utterance_s=1.0)
        s = VoiceSession(config=c)
        self.assertTrue(s.vad_should_emit(30, 0, 50))     # 1s 上限（50 帧）


if __name__ == "__main__":
    unittest.main()
