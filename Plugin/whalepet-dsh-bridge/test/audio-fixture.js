/** 测试用音频合成：生成能量 VAD 能识别的「说话」帧与静音帧。 */

const SAMPLE_RATE = 16000
const FRAME_SAMPLES = 320 // 20ms

/** 生成正弦 PCM16 帧序列（每帧固定 20ms）。 */
export function toneFrames({ frames = 5, amplitude = 8000, frequency = 220, sampleRate = SAMPLE_RATE } = {}) {
  const chunks = []
  for (let frame = 0; frame < frames; frame += 1) {
    const buffer = Buffer.alloc(FRAME_SAMPLES * 2)
    for (let i = 0; i < FRAME_SAMPLES; i += 1) {
      const n = frame * FRAME_SAMPLES + i
      const value = Math.round(amplitude * Math.sin((2 * Math.PI * frequency * n) / sampleRate))
      buffer.writeInt16LE(value, i * 2)
    }
    chunks.push(buffer)
  }
  return Buffer.concat(chunks)
}

/** 生成静音帧（全 0）。 */
export function silenceFrames(frames = 5) {
  return Buffer.alloc(FRAME_SAMPLES * 2 * frames)
}

/** 生成轻微底噪帧，供噪声底跟踪测试。 */
export function noiseFrames(frames = 5, amplitude = 40) {
  const buffer = Buffer.alloc(FRAME_SAMPLES * 2 * frames)
  let seed = 42
  for (let i = 0; i < FRAME_SAMPLES * frames; i += 1) {
    // 线性同余伪随机，保证可复现。
    seed = (seed * 1103515245 + 12345) & 0x7fffffff
    const value = Math.round(((seed % (2 * amplitude + 1)) - amplitude) * 1)
    buffer.writeInt16LE(value, i * 2)
  }
  return buffer
}

/** 一段「说话 + 尾部静音」的完整语句。 */
export function utterance({ speechFrames = 8, tailSilenceFrames = 40, amplitude = 8000 } = {}) {
  return Buffer.concat([toneFrames({ frames: speechFrames, amplitude }), silenceFrames(tailSilenceFrames)])
}