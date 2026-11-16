// 录音小工具：录真人语音，用来标定本地唤醒词阈值。
//
// 用法（先编译再跑）：
//   swiftc -O tool/record_wake_word.swift -o /tmp/record_wake_word
//   /tmp/record_wake_word <输出.wav> [录音秒数，默认 3]
//
// 录的是麦克风原始格式的 wav，之后用 afconvert 转成 16kHz 单声道再喂给
// tool/verify_kws.c 验证。

import AVFoundation
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
  print("用法: record_wake_word <输出.wav> [秒数]")
  exit(2)
}
let outputPath = args[1]
let duration = args.count >= 3 ? (Double(args[2]) ?? 3.0) : 3.0

let session = AVAudioSession.sharedInstance()
var granted = false
switch session.recordPermission {
case .granted:
  granted = true
case .undetermined:
  granted = false
  session.requestRecordPermission { ok in
    if !ok {
      print("麦克风权限被拒绝")
      exit(1)
    }
  }
  // 等回调；这里用轮询兜底（Swift 顶层脚本不适合直接跑异步闭包）
  let deadline = Date().addingTimeInterval(10)
  while Date() < deadline && !granted {
    Thread.sleep(forTimeInterval: 0.1)
    granted = session.recordPermission == .granted
  }
default:
  print("麦克风权限被拒绝")
  exit(1)
}
if !granted {
  print("麦克风权限未授予")
  exit(1)
}

try? session.setCategory(.record, mode: .measurement, options: [])
try? session.setActive(true)

let engine = AVAudioEngine()
let input = engine.inputNode
let format = input.outputFormat(forBus: 0)
guard format.sampleRate > 0 else {
  print("没有可用的音频输入设备")
  exit(1)
}

let url = URL(fileURLWithPath: outputPath)
let settings: [String: Any] = [
  AVFormatIDKey: Int(kAudioFormatLinearPCM),
  AVSampleRateKey: format.sampleRate,
  AVNumberOfChannelsKey: 1,
  AVLinearPCMBitDepthKey: 16,
  AVLinearPCMIsFloatKey: false,
  AVLinearPCMIsBigEndianKey: false,
]
let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: false)

let sampleRate = format.sampleRate
print("录音中（\(String(format: "%.0f", duration)) 秒），请说：小鲸小鲸")
print("采样率 \(sampleRate)Hz，输出 \(outputPath)")

input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
  try? file.write(from: buffer)
}

engine.prepare()
try engine.start()

let end = Date().addingTimeInterval(duration)
while Date() < end {
  Thread.sleep(forTimeInterval: 0.1)
  let left = end.timeIntervalSinceNow
  if Int(left * 10) % 10 == 0 {
    print(String(format: "  剩余 %.1f 秒", max(0, left)))
  }
}

engine.inputNode.removeTap(onBus: 0)
engine.stop()
print("录完了：\(outputPath)")
