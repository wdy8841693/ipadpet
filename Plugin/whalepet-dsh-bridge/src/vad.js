/**
 * 轻量能量 VAD + 语句切分（纯逻辑，无 I/O）。
 *
 * 原 Python 桥接用 webrtcvad（WebRTC VAD）。插件里不引入原生依赖，
 * 改用自适应噪声底 + 迟滞的能量判定：
 *   - 每 20ms 一帧（16k/16bit，320 字节）；
 *   - 说话阈值 = max(noiseFloor + marginDb, floorDbfs)，噪声底只在静音帧上慢速跟进；
 *   - 起音需要连续 N 帧过阈，判停由 session.vadShouldEmit 的静音帧计数决定。
 *
 * 取舍：安静室内足够；强噪声环境比不上 WebRTC VAD（README 里有说明与调参项）。
 */

/** PCM16 小端单声道帧 -> dBFS（-Infinity 表示数字静音）。 */
export function frameDbfs(frame) {
  const samples = Math.floor(frame.length / 2)
  if (samples === 0) return -Infinity
  let sum = 0
  for (let i = 0; i < samples; i += 1) {
    const s = frame.readInt16LE(i * 2)
    sum += s * s
  }
  const rms = Math.sqrt(sum / samples)
  if (rms === 0) return -Infinity
  return 20 * Math.log10(rms / 32768)
}

const DEFAULTS = {
  /** 绝对下限：低于此值一定不算说话。 */
  floorDbfs: -55,
  /** 相对噪声底的门限余量。 */
  marginDb: 10,
  /** 噪声底向上/向下跟进的速率（每帧）。 */
  noiseUpRate: 0.05,
  noiseDownRate: 0.01,
  /** 起音去抖：连续多少帧过阈才算开口。 */
  onsetFrames: 2,
  /** 初始噪声底。 */
  initialNoiseDbfs: -60,
}

/** 自适应能量 VAD。 */
export class EnergyVad {
  constructor(options = {}) {
    this.options = { ...DEFAULTS, ...options }
    if (!Number.isFinite(this.options.initialNoiseDbfs)) this.options.initialNoiseDbfs = DEFAULTS.initialNoiseDbfs
    this.noiseFloor = this.options.initialNoiseDbfs
    this.onsetRun = 0
  }

  /** 当前帧是否是语音（带起音去抖）。 */
  isSpeech(frame, dbOverride) {
    const db = dbOverride ?? frameDbfs(frame)
    if (!Number.isFinite(db)) {
      this.#observeSilence()
      return false
    }
    const threshold = Math.max(this.options.floorDbfs, this.noiseFloor + this.options.marginDb)
    const loud = db > threshold
    if (loud) {
      this.onsetRun += 1
      return this.onsetRun >= this.options.onsetFrames
    }
    this.onsetRun = 0
    this.#observeSilence(db)
    return false
  }

  /** 一帧被判定为静音后更新噪声底（只向下慢、向上快一点，避免把说话声当地噪）。 */
  #observeSilence(db) {
    if (!Number.isFinite(db)) return
    const target = Math.min(db, this.noiseFloor + this.options.marginDb - 1)
    const rate = target < this.noiseFloor ? this.options.noiseDownRate : this.options.noiseUpRate
    this.noiseFloor = target < this.noiseFloor
      ? this.noiseFloor + (target - this.noiseFloor) * this.options.noiseDownRate
      : this.noiseFloor + (target - this.noiseFloor) * rate
  }

  /** 重置（新连接 / 手动打断后）。 */
  reset() {
    this.onsetRun = 0
  }

  get state() {
    return { noiseFloor: this.noiseFloor, onsetRun: this.onsetRun }
  }
}

/** 按固定帧长切分任意长度的 PCM 数据。 */
export class FrameSplitter {
  constructor(frameBytes, onFrame) {
    this.frameBytes = frameBytes
    this.onFrame = onFrame
    this.buffer = Buffer.alloc(0)
  }

  push(chunk) {
    if (!chunk || chunk.length === 0) return
    this.buffer = this.buffer.length === 0 ? Buffer.from(chunk) : Buffer.concat([this.buffer, chunk])
    while (this.buffer.length >= this.frameBytes) {
      const frame = this.buffer.subarray(0, this.frameBytes)
      this.buffer = this.buffer.subarray(this.frameBytes)
      this.onFrame(frame)
    }
  }

  reset() {
    this.buffer = Buffer.alloc(0)
  }
}

/**
 * 语句切分器：pre-roll 保证起始辅音不丢，判停交给 VoiceSession.vadShouldEmit。
 */
export class UtteranceSegmenter {
  /**
   * @param {ReturnType<import('./session.js').voiceConfig>} config
   * @param {import('./session.js').VoiceSession} session
   * @param {EnergyVad} vad
   */
  constructor(config, session, vad) {
    this.config = config
    this.session = session
    this.vad = vad
    this.preRoll = []
    /** @type {Buffer[]|null} */
    this.utterance = null
    this.voicedFrames = 0
    this.silenceRun = 0
    this.totalFrames = 0
  }

  /** 处理一帧；返回待识别的 PCM Buffer 或 null。 */
  push(frame) {
    const voiced = this.vad.isSpeech(frame)
    this.totalFrames += 1

    if (voiced) {
      if (this.utterance === null) {
        this.utterance = [...this.preRoll]
        this.voicedFrames = 0
        this.silenceRun = 0
      }
      this.voicedFrames += 1
      this.silenceRun = 0
      this.utterance.push(frame)
    } else {
      this.preRoll.push(frame)
      if (this.preRoll.length > this.config.preRollFrames) {
        this.preRoll.splice(0, this.preRoll.length - this.config.preRollFrames)
      }
      if (this.utterance !== null) {
        // 尾部静音也计入语音段（ASR 需要听到句尾）。
        this.utterance.push(frame)
        this.silenceRun += 1
      }
    }

    if (this.session.vadShouldEmit(this.voicedFrames, this.silenceRun, this.totalFrames)) {
      const parts = this.utterance ?? []
      const pcm = parts.length > 0 ? Buffer.concat(parts) : Buffer.alloc(0)
      this.reset()
      return pcm.length > 0 ? pcm : null
    }
    return null
  }

  reset() {
    this.preRoll = []
    this.utterance = null
    this.voicedFrames = 0
    this.silenceRun = 0
    this.totalFrames = 0
    this.vad.reset()
  }
}