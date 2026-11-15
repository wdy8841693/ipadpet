/**
 * describeQuestion：把「需要你选择」的题目整理成一句能念的中文。
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'

import { describeQuestion, firstQuestion } from '../src/question-text.js'

test('describeQuestion：题目 + 选项按口语序数词念', () => {
  const spoken = describeQuestion({
    question: '要把文件保存到哪个目录？',
    options: [{ label: '工作区' }, { label: '桌面' }],
  })
  assert.match(spoken, /要把文件保存到哪个目录/)
  assert.match(spoken, /第一个 工作区/)
  assert.match(spoken, /第二个 桌面/)
  assert.match(spoken, /去 DSH 里选一下/)
  // 不能念出列表符号
  assert.doesNotMatch(spoken, /^[\d.\-*]\s/m)
})

test('describeQuestion：多选会说明「可以多选」', () => {
  const spoken = describeQuestion({
    question: '要修改哪些文件？',
    options: [{ label: 'a.js' }, { label: 'b.js' }],
    multiSelect: true,
  })
  assert.match(spoken, /可以多选/)
})

test('describeQuestion：没有选项时退回通用提示', () => {
  const spoken = describeQuestion({ question: '你的项目名是什么？' })
  assert.match(spoken, /你的项目名是什么/)
  assert.match(spoken, /去 DSH 里回一下/)
  assert.doesNotMatch(spoken, /选项/)
})

test('describeQuestion：选项过多只念前 3 个并提示还有几个', () => {
  const spoken = describeQuestion({
    question: '选一个方案',
    options: [{ label: '甲' }, { label: '乙' }, { label: '丙' }, { label: '丁' }, { label: '戊' }],
  })
  assert.match(spoken, /第一个 甲/)
  assert.match(spoken, /第三个 丙/)
  assert.doesNotMatch(spoken, /第四个/)
  assert.match(spoken, /还有 2 个选项去 DSH 里看/)
})

test('describeQuestion：长文本与换行被压成一行并截断', () => {
  const spoken = describeQuestion({
    question: '第一行\n\n第二行，'.repeat(10),
    options: [{ label: '这是一个非常非常长的选项名称需要截断' }],
    questionChars: 20,
    optionChars: 8,
  })
  assert.doesNotMatch(spoken, /\n/)
  // 题目截断到 20 字 + 省略号
  const stem = spoken.split('。')[0]
  assert.equal([...stem].length, 21)
  assert.match(spoken, /这是一个非常非常…/)
})

test('describeQuestion：空请求也能给出可用文案', () => {
  const spoken = describeQuestion()
  assert.match(spoken, /有个问题需要你回答/)
  assert.match(spoken, /去 DSH 里回一下/)
})

test('firstQuestion：取第一道题', () => {
  const request = { questions: [{ id: 'q1', question: '选哪个？' }, { id: 'q2', question: '第二个' }] }
  assert.equal(firstQuestion(request).id, 'q1')
  assert.equal(firstQuestion({}), undefined)
  assert.equal(firstQuestion(undefined), undefined)
})