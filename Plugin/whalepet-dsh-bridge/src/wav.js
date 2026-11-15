/**
 * PCM16 -> WAV（纯逻辑）。
 *
 * dsh-experimental-speech-to-text 只接受「规范 16kHz 单声道 PCM16 WAV」，
 * 这里按 RIFF/WAVE 最小头拼装；与 Server/whalepet_bridge/asr.py 的
 * pcm16_to_wav_bytes 等价。
 */

/**
 * @param {Buffer} pcm 16-bit little-endian mono PCM
 * @param {number} [sampleRate]
 * @returns {Buffer} 完整 WAV 文件字节
 */
export function pcm16ToWav(pcm, sampleRate = 16000) {
  if (!Buffer.isBuffer(pcm)) throw new TypeError('pcm16ToWav 需要 Buffer')
  if (pcm.length % 2 !== 0) throw new RangeError('PCM 字节数必须是 2 的整数倍')
  const channels = 1
  const bitsPerSample = 16
  const byteRate = (sampleRate * channels * bitsPerSample) / 8
  const blockAlign = (channels * bitsPerSample) / 8
  const header = Buffer.alloc(44)
  header.write('RIFF', 0, 'ascii')
  header.writeUInt32LE(36 + pcm.length, 4)
  header.write('WAVE', 8, 'ascii')
  header.write('fmt ', 12, 'ascii')
  header.writeUInt32LE(16, 16) // fmt chunk size
  header.writeUInt16LE(1, 20) // PCM
  header.writeUInt16LE(channels, 22)
  header.writeUInt32LE(sampleRate, 24)
  header.writeUInt32LE(byteRate, 28)
  header.writeUInt16LE(blockAlign, 32)
  header.writeUInt16LE(bitsPerSample, 34)
  header.write('data', 36, 'ascii')
  header.writeUInt32LE(pcm.length, 40)
  return Buffer.concat([header, pcm])
}

/** 解析 WAV 头（测试/调试用）：返回 {sampleRate, channels, bitsPerSample, dataOffset, dataLength}。 */
export function parseWavHeader(wav) {
  if (!Buffer.isBuffer(wav) || wav.length < 44) throw new RangeError('WAV 太短')
  if (wav.toString('ascii', 0, 4) !== 'RIFF' || wav.toString('ascii', 8, 12) !== 'WAVE') {
    throw new RangeError('不是 RIFF/WAVE')
  }
  let offset = 12
  let fmt = null
  while (offset + 8 <= wav.length) {
    const id = wav.toString('ascii', offset, offset + 4)
    const size = wav.readUInt32LE(offset + 4)
    const body = offset + 8
    if (id === 'fmt ') {
      fmt = {
        format: wav.readUInt16LE(body),
        channels: wav.readUInt16LE(body + 2),
        sampleRate: wav.readUInt32LE(body + 4),
        bitsPerSample: wav.readUInt16LE(body + 14),
      }
    } else if (id === 'data') {
      if (!fmt) throw new RangeError('缺少 fmt chunk')
      return { ...fmt, dataOffset: body, dataLength: size }
    }
    offset = body + size + (size % 2)
  }
  throw new RangeError('缺少 data chunk')
}