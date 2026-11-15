import test from 'node:test'
import assert from 'node:assert/strict'
import { EnergyVad, FrameSplitter, UtteranceSegmenter, frameDbfs } from '../src/vad.js'
import { VoiceSession, voiceConfig } from '../src/session.js'
import { WakeMatcher } from '../src/textnorm.js'
import { toneFrames, silenceFrames, noiseFrames } from './audio-fixture.js'

test('frameDbfs: 静音为 -Infinity，正弦约为预期量级', () => {
  assert.equal(frameDbfs(silenceFrames(1)), -Infinity)
  const db = frameDbfs(toneFrames({ frames: 1, amplitude: 8000 }))
  assert.ok(db > -20 && db < -10, `实际 ${db}`)
})

test('EnergyVad: 静音不触发、人声触发（带起音去抖）', () => {
  const vad = new EnergyVad()
  const speech = toneFrames({ frames: 1 })
  assert.equal(vad.isSpeech(speech), false) // 起音第 1 帧
  assert.equal(vad.isSpeech(speech), true) // 起音第 2 帧
  vad.reset()
  assert.equal(vad.isSpeech(silenceFrames(1)), false)
})

test('EnergyVad: 阈下底噪会被慢慢抬高噪声底', () => {
  const vad = new EnergyVad()
  const start = vad.noiseFloor
  const quietNoise = noiseFrames(1, 120) // 约 -53 dBFS，低于初始门限 -50
  for (let i = 0; i < 300; i += 1) vad.isSpeech(quietNoise)
  assert.ok(vad.noiseFloor > start + 3, `噪声底 ${vad.noiseFloor} 起始 ${start}`)
  assert.ok(vad.noiseFloor < -48, `噪声底不应越过底噪本身: ${vad.noiseFloor}`)
})

test('FrameSplitter: 任意长度数据切成固定帧', () => {
  const frames = []
  const splitter = new FrameSplitter(320, (frame) => frames.push(frame))
  const data = Buffer.alloc(320 * 3 + 100)
  splitter.push(data.subarray(0, 200))
  assert.equal(frames.length, 0)
  splitter.push(data.subarray(200))
  assert.equal(frames.length, 3)
  assert.equal(frames[0].length, 320)
})

test('UtteranceSegmenter: 说话 + 尾部静音产出完整语句（含 pre-roll）', () => {
  const config = voiceConfig({ silenceMs: 200, preRollMs: 100 })
  const session = new VoiceSession(new WakeMatcher(), config)
  const vad = new EnergyVad()
  const segmenter = new UtteranceSegmenter(config, session, vad)
  const splitter = new FrameSplitter(config.frameBytes, (frame) => {
    const pcm = segmenter.push(frame)
    if (pcm) emitted.push(pcm)
  })
  const emitted = []

  // 先给 3 帧静音积累 pre-roll，再说 5 帧，再静音到判停。
  splitter.push(silenceFrames(3))
  splitter.push(toneFrames({ frames: 5 }))
  splitter.push(silenceFrames(15))

  assert.equal(emitted.length, 1)
  // pre-roll(3) + 语音(5) + 尾部静音(10) = 18 帧
  assert.equal(emitted[0].length, config.frameBytes * 18)
})