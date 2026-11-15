/**
 * 语音会话状态机（纯逻辑，无 I/O）。
 *
 * 移植自 Server/whalepet_bridge/session_state.py：
 *   waiting   前台待唤醒
 *   listening 已唤醒，等待下一条命令
 *
 * VAD 帧计数规则也在这一层，便于单测。
 */

import { isValidCommand } from './textnorm.js'

/** @typedef {'waiting'|'listening'} VoicePhase */

export const PHASE = Object.freeze({
  WAITING: 'waiting',
  LISTENING: 'listening',
})

/** 唤醒结果。 */
export const WAKE = Object.freeze({
  NONE: 'none',
  WAKE_ONLY: 'wake_only',
  WAKE_WITH_COMMAND: 'wake_command',
})

/** VAD / 采集调参（与 Python 侧默认值一致）。 */
export function voiceConfig(overrides = {}) {
  const merged = {
    sampleRate: 16000,
    frameMs: 20,
    preRollMs: 300,
    silenceMs: 700,
    maxUtteranceS: 20,
    listenTimeoutS: 10,
    ...overrides,
  }
  const frameBytes = Math.floor((merged.sampleRate * merged.frameMs) / 1000) * 2
  return {
    ...merged,
    frameBytes,
    preRollFrames: Math.max(1, Math.floor(merged.preRollMs / merged.frameMs)),
    silenceFrames: Math.max(1, Math.floor(merged.silenceMs / merged.frameMs)),
    maxUtteranceFrames: Math.max(1, Math.floor((merged.maxUtteranceS * 1000) / merged.frameMs)),
  }
}

/** 一个客户端的唤醒/命令相位。与传输层无关。 */
export class VoiceSession {
  /**
   * @param {import('./textnorm.js').WakeMatcher} matcher
   * @param {ReturnType<typeof voiceConfig>} config
   */
  constructor(matcher, config = voiceConfig()) {
    this.matcher = matcher
    this.config = config
    /** @type {VoicePhase} */
    this.phase = PHASE.WAITING
  }

  /** 等待态下一段语音：判断是否唤醒。 */
  feedWaiting(utterance) {
    const { matched, command } = this.matcher.match(utterance)
    if (!matched) return { outcome: WAKE.NONE, command: '' }
    if (isValidCommand(command)) {
      // 一句话带命令：直接执行，不进入 listening。
      this.phase = PHASE.WAITING
      return { outcome: WAKE.WAKE_WITH_COMMAND, command }
    }
    this.phase = PHASE.LISTENING
    return { outcome: WAKE.WAKE_ONLY, command: '' }
  }

  /** 聆听态下一段语音：任何有效命令都交付。 */
  feedListening(utterance) {
    if (isValidCommand(utterance)) {
      this.phase = PHASE.WAITING
      return { ok: true, command: utterance }
    }
    return { ok: false, command: '' }
  }

  manualStart() {
    this.phase = PHASE.LISTENING
  }

  reset() {
    this.phase = PHASE.WAITING
  }

  /**
   * 一段话是否该结束并送识别：
   *  - 至少出现过有声帧；
   *  - 尾部连续静音达到 silenceFrames，或总长达到上限。
   */
  vadShouldEmit(voicedFrames, silenceRun, totalFrames) {
    if (voicedFrames === 0) return false
    return totalFrames >= this.config.maxUtteranceFrames || silenceRun >= this.config.silenceFrames
  }
}