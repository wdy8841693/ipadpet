"""Pure-logic tests for text normalization and wake matching."""
from __future__ import annotations

import unittest

from whalepet_bridge.textnorm import (
    VoiceSessionConfig,
    WakeMatcher,
    is_valid_command,
    normalize,
    session_id_ok,
)


class TestNormalize(unittest.TestCase):
    def test_punctuation_and_spaces(self):
        self.assertEqual(normalize("小鲸小鲸，帮我看看天气。"), "小鲸小鲸 帮我看看天气")
        self.assertEqual(normalize("  小鲸  小鲸  "), "小鲸小鲸")

    def test_fullwidth_and_case(self):
        self.assertEqual(normalize("ＡＢＣ ｄｅｆ"), "abc def")
        self.assertEqual(normalize("Ｈello！"), "hello")

    def test_empty(self):
        self.assertEqual(normalize(""), "")
        self.assertEqual(normalize("，。！"), "")

    def test_han_space_removed(self):
        self.assertEqual(normalize("帮 我 查 一 下"), "帮我查一下")


class TestWakeMatcher(unittest.TestCase):
    def setUp(self):
        self.m = WakeMatcher()

    def test_wake_only(self):
        matched, cmd = self.m.match("小鲸小鲸")
        self.assertTrue(matched)
        self.assertEqual(cmd, "")

    def test_wake_with_punct(self):
        matched, cmd = self.m.match("小鲸小鲸！")
        self.assertTrue(matched)
        self.assertEqual(cmd, "")

    def test_wake_with_command(self):
        matched, cmd = self.m.match("小鲸小鲸，帮我查天气")
        self.assertTrue(matched)
        self.assertEqual(cmd, "帮我查天气")

    def test_wake_with_command_no_punct(self):
        matched, cmd = self.m.match("小鲸小鲸 帮我查天气")
        self.assertTrue(matched)
        self.assertEqual(cmd, "帮我查天气")

    def test_no_match(self):
        matched, _ = self.m.match("今天天气怎么样")
        self.assertFalse(matched)

    def test_alias(self):
        matched, cmd = self.m.match("小金小金，打开灯")
        self.assertTrue(matched)
        self.assertEqual(cmd, "打开灯")

    def test_custom_alias(self):
        m = WakeMatcher(wake_phrase="小鲸小鲸", aliases=("小晶晶",))
        matched, cmd = m.match("小晶晶 帮我倒计时")
        self.assertTrue(matched)
        self.assertEqual(cmd, "帮我倒计时")

    def test_prefix_inside_longer_word(self):
        # 唤醒词必须出现在开头；前面多一个字不算唤醒。
        matched, _ = self.m.match("小小鲸小鲸")
        self.assertFalse(matched)

    def test_middle_occurrence_not_wake(self):
        matched, _ = self.m.match("我说小鲸小鲸之后呢")
        self.assertFalse(matched)


class TestCommandValidation(unittest.TestCase):
    def test_valid(self):
        self.assertTrue(is_valid_command("开灯"))
        self.assertTrue(is_valid_command("帮我看下明天的日程"))

    def test_invalid(self):
        self.assertFalse(is_valid_command(""))
        self.assertFalse(is_valid_command("嗯"))
        self.assertFalse(is_valid_command("。，！"))


class TestSessionId(unittest.TestCase):
    def test_ok(self):
        self.assertTrue(session_id_ok("pet-001"))
        self.assertTrue(session_id_ok("ABC_123"))

    def test_bad(self):
        self.assertFalse(session_id_ok(""))
        self.assertFalse(session_id_ok("a" * 65))
        self.assertFalse(session_id_ok("../etc"))
        self.assertFalse(session_id_ok("会话 1"))
        self.assertFalse(session_id_ok(None))


class TestVoiceSessionConfig(unittest.TestCase):
    def test_frame_math(self):
        c = VoiceSessionConfig()
        self.assertEqual(c.frame_bytes, 640)  # 16000 * 0.02 * 2
        self.assertEqual(c.silence_frames, 35)  # 700ms / 20ms
        self.assertEqual(c.pre_roll_frames, 15)
        self.assertEqual(c.max_utterance_frames, 1000)


if __name__ == "__main__":
    unittest.main()
