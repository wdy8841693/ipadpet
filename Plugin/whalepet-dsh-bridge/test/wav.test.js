import test from 'node:test'
import assert from 'node:assert/strict'
import { pcm16ToWav, parseWavHeader } from '../src/wav.js'

test('pcm16ToWav: 生成规范 44 字节头 + 数据', () => {
  const pcm = Buffer.alloc(320, 1) // 一个 20ms 帧
  const wav = pcm16ToWav(pcm)
  assert.equal(wav.length, pcm.length + 44)
  assert.equal(wav.toString('ascii', 0, 4), 'RIFF')
  assert.equal(wav.toString('ascii', 8, 12), 'WAVE')
  assert.equal(wav.readUInt32LE(4), 36 + pcm.length)

  const header = parseWavHeader(wav)
  assert.equal(header.format, 1) // PCM
  assert.equal(header.channels, 1)
  assert.equal(header.sampleRate, 16000)
  assert.equal(header.bitsPerSample, 16)
  assert.equal(header.dataLength, pcm.length)
  assert.deepEqual(wav.subarray(header.dataOffset, header.dataOffset + pcm.length), pcm)
})

test('pcm16ToWav: 非法输入被拒绝', () => {
  assert.throws(() => pcm16ToWav(Buffer.alloc(3)), /整数倍/)
  assert.throws(() => pcm16ToWav('not a buffer'), /Buffer/)
})

test('parseWavHeader: 非 RIFF 输入被拒绝', () => {
  assert.throws(() => parseWavHeader(Buffer.alloc(64)), /RIFF/)
})