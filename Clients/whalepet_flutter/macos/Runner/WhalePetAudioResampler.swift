import AVFoundation
import Foundation

/// 任意输入格式 → 16kHz 单声道 Float32 的线性重采样器。
///
/// 唤醒词模型（sherpa-onnx KWS）固定吃 16kHz 单声道，而麦克风给到的格式随机器
/// 而变（44.1k/48k，单声道/双声道都有）。这里自己做重采样而不是让 AVAudioEngine
/// 在 tap 里转格式：引擎的格式转换在部分机器/格式上会失败，自己算最稳，
/// 行为也可预期。
///
/// 用法：每个 tap 回调把 [Float] 丢进来，拿回重采样后的 16k 单声道。
final class WhalePetAudioResampler {

  /// 输出采样率：KWS 模型的要求，不要改。
  static let outputSampleRate: Double = 16000

  /// 输入采样率 → 输出采样率的步长（每输出一个样本，输入要前进多少）。
  private let step: Double

  /// 下一个输出样本在「全局输入流」中的位置。
  private var nextPosition: Double = 0

  /// 最近的历史样本（最多 2 个）：跨缓冲区插值时要用到上一块的尾巴。
  private var history: [Float] = []

  /// 当前缓冲区首样本在全局输入流中的索引。
  private var globalBase: Int = 0

  init(inputSampleRate: Double) {
    step = inputSampleRate / WhalePetAudioResampler.outputSampleRate
  }

  /// 把一个采集缓冲区重采样成 16kHz 单声道（多声道只取第一路）。
  func process(buffer: AVAudioPCMBuffer) -> [Float] {
    guard let channelData = buffer.floatChannelData else { return [] }
    let frames = Int(buffer.frameLength)
    guard frames > 0 else { return [] }
    let input = channelData[0]
    return process(input: input, frames: frames)
  }

  /// 重采样一段连续采样（测试用；采集路径走 `process(buffer:)`）。
  func process(input: [Float]) -> [Float] {
    return input.withUnsafeBufferPointer { ptr in
      guard let base = ptr.baseAddress else { return [] }
      return process(input: base, frames: ptr.count)
    }
  }

  private func process(input: UnsafePointer<Float>, frames: Int) -> [Float] {
    guard frames > 0, step > 0 else { return [] }

    let end = globalBase + frames
    var out: [Float] = []
    out.reserveCapacity(Int(Double(frames) / step) + 2)

    // 只输出「插值的两个端点都已经在手」的样本；差一个的那一个留到下一块，
    // 避免用 0 补边界产生咔哒声。
    while nextPosition < Double(end - 1) {
      let index = Int(nextPosition)
      let fraction = Float(nextPosition - Double(index))
      let x0 = sample(at: index, input: input, frames: frames)
      let x1 = sample(at: index + 1, input: input, frames: frames)
      out.append(x0 + fraction * (x1 - x0))
      nextPosition += step
    }

    for i in 0..<frames {
      history.append(input[i])
      if history.count > 2 { history.removeFirst() }
    }
    globalBase += frames
    return out
  }

  /// 取全局第 [index] 个输入样本：旧的从历史里取，新的从当前缓冲区取。
  private func sample(at index: Int, input: UnsafePointer<Float>, frames: Int) -> Float {
    if index < globalBase {
      let relative = index - (globalBase - history.count)
      guard relative >= 0, relative < history.count else { return 0 }
      return history[relative]
    }
    let relative = index - globalBase
    guard relative >= 0, relative < frames else { return 0 }
    return input[relative]
  }
}
