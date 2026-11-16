import Cocoa
import FlutterMacOS

/// 主窗口：桌宠容器（docs/CROSS_PLATFORM.md §6.3、§10.2）。
///
/// 「操作系统窗口本身就是宠物」：透明、无边框、置顶、常驻所有空间；
/// Dock 隐藏与鼠标穿透由 AppDelegate 处理。
class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // ---- 透明：窗口与 Flutter 图层都要 clear，否则有黑底 ----
    self.isOpaque = false
    self.backgroundColor = NSColor.clear
    flutterViewController.backgroundColor = NSColor.clear

    // ---- 无边框：去标题栏与系统按钮，不留阴影（阴影会画出窗口矩形）----
    self.styleMask.remove(.titled)
    self.styleMask.insert(.borderless)
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.hasShadow = false

    // 按住宠物区域可以拖动窗口（对 Flutter 已接管的区域无效，拖拽主走
    // whalepet/window 通道的 startNativeDrag → performDrag）。
    self.isMovableByWindowBackground = true

    // ---- 置顶 + 常驻所有空间 ----
    self.level = .floating
    self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    super.awakeFromNib()
  }
}
