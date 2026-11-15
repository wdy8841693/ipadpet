import test from 'node:test'
import assert from 'node:assert/strict'
import { DEFAULT_WAKE_ALIASES, WakeMatcher, isValidCommand, isValidSessionId, normalize } from '../src/textnorm.js'
import { VoiceSession, PHASE, WAKE, voiceConfig } from '../src/session.js'

test('normalize: NFKC/大小写/汉字空格/标点折叠', () => {
  assert.equal(normalize('  小鲸 小鲸 ！ '), '小鲸小鲸')
  assert.equal(normalize('Hello, World!'), 'hello world')
  assert.equal(normalize(''), '')
  assert.equal(normalize(undefined), '')
  assert.equal(normalize('小鲸小鲸，帮我看看天气？'), '小鲸小鲸 帮我看看天气')
})

test('WakeMatcher: 只说唤醒词 -> 唤醒、无命令', () => {
  const matcher = new WakeMatcher()
  assert.deepEqual(matcher.match('小鲸小鲸'), { matched: true, command: '' })
  assert.deepEqual(matcher.match('小鲸小鲸！'), { matched: true, command: '' })
})

test('WakeMatcher: 一句话带命令', () => {
  const matcher = new WakeMatcher()
  assert.deepEqual(matcher.match('小鲸小鲸，现在几点了？'), { matched: true, command: '现在几点了' })
  assert.deepEqual(matcher.match('小鲸小鲸帮我讲个笑话'), { matched: true, command: '帮我讲个笑话' })
})

test('WakeMatcher: 同音别名与自定义唤醒词', () => {
  const matcher = new WakeMatcher()
  assert.equal(matcher.match('小金小金').matched, true)
  assert.equal(matcher.match('晓鲸晓鲸 你好').matched, true)
  const custom = new WakeMatcher({ wakePhrase: '小胖小胖', aliases: [] })
  assert.equal(custom.match('小胖小胖').matched, true)
  assert.equal(custom.match('小鲸小鲸').matched, false)
})

test('WakeMatcher: 环境人声不误唤醒', () => {
  const matcher = new WakeMatcher()
  assert.equal(matcher.match('今天下午开会').matched, false)
  assert.equal(matcher.match('').matched, false)
  assert.equal(matcher.match('小鲸').matched, false)
})

test('默认别名表非空且包含主唤醒词', () => {
  assert.ok(DEFAULT_WAKE_ALIASES.includes('小鲸小鲸'))
})

test('isValidCommand / isValidSessionId', () => {
  assert.equal(isValidCommand('来'), false)
  assert.equal(isValidCommand('你好'), true)
  assert.equal(isValidCommand('，。'), false)
  assert.equal(isValidSessionId('pet-001'), true)
  assert.equal(isValidSessionId('pet 001'), false)
  assert.equal(isValidSessionId('a'.repeat(65)), false)
  assert.equal(isValidSessionId(123), false)
})

test('VoiceSession: 等待 -> 唤醒 -> 聆听 -> 命令 -> 回到等待', () => {
  const session = new VoiceSession(new WakeMatcher(), voiceConfig())
  assert.equal(session.phase, PHASE.WAITING)

  const wake = session.feedWaiting('小鲸小鲸')
  assert.deepEqual(wake, { outcome: WAKE.WAKE_ONLY, command: '' })
  assert.equal(session.phase, PHASE.LISTENING)

  const miss = session.feedWaiting('随便说点什么')
  assert.equal(miss.outcome, WAKE.NONE)

  const command = session.feedListening('今天天气怎么样')
  assert.deepEqual(command, { ok: true, command: '今天天气怎么样' })
  assert.equal(session.phase, PHASE.WAITING)
})

test('VoiceSession: 一句话带命令不进入聆听态', () => {
  const session = new VoiceSession(new WakeMatcher(), voiceConfig())
  const result = session.feedWaiting('小鲸小鲸 讲个笑话')
  assert.deepEqual(result, { outcome: WAKE.WAKE_WITH_COMMAND, command: '讲个笑话' })
  assert.equal(session.phase, PHASE.WAITING)
})

test('VoiceSession: 聆听态过短输入被忽略', () => {
  const session = new VoiceSession(new WakeMatcher(), voiceConfig())
  session.manualStart()
  assert.deepEqual(session.feedListening('嗯'), { ok: false, command: '' })
  assert.equal(session.phase, PHASE.LISTENING)
})

test('VoiceSession: VAD 判停规则', () => {
  const config = voiceConfig({ silenceMs: 200, maxUtteranceS: 1 })
  const session = new VoiceSession(new WakeMatcher(), config)
  assert.equal(config.silenceFrames, 10)
  assert.equal(session.vadShouldEmit(0, 0, 0), false)
  assert.equal(session.vadShouldEmit(1, 0, 1), false)
  assert.equal(session.vadShouldEmit(1, 9, 10), false)
  assert.equal(session.vadShouldEmit(1, 10, 11), true)
  assert.equal(session.vadShouldEmit(1, 0, config.maxUtteranceFrames), true)
})