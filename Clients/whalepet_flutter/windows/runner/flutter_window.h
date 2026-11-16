#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>

#include "tray_icon.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
//
// 除了托管 Flutter 视图，这个类还承担两件 Windows 特有的事（§10.3）：
//   - 托盘图标（`tray_icon.h`）：桌宠窗口不在任务栏，托盘是隐藏后唯一的入口；
//   - `whalepet/desktop` 通道：把「显示器/工作区变了」「托盘菜单点了什么」
//     推给 Dart，Dart 侧再决定窗口位置、语音开关等行为。
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // 显示器/工作区变了（插拔显示器、改分辨率、换主屏、DPI 变化）。
  void NotifyDisplayChanged();

  // 托盘菜单动作（显示/隐藏、语音唤醒、设置、退出）。
  void NotifyTrayAction(const std::wstring& action);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // 与 Dart 侧 `Win32DesktopChannel` 对应的桌面通道。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      desktop_channel_;

  // 托盘图标。
  std::unique_ptr<TrayIcon> tray_;

  // Explorer 重启后会广播这个消息，需要重新注册托盘图标。
  UINT taskbar_created_message_ = 0;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
