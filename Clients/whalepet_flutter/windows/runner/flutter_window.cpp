#include "flutter_window.h"

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

namespace {

// 托盘回调消息：落在 WM_APP 之后的自定义区间，避开系统消息。
constexpr UINT kTrayCallbackMessage = WM_APP + 1;

// std::wstring -> UTF-8 std::string（EncodableValue 的字符串用 UTF-8）。
std::string Utf8FromWide(const std::wstring& text) {
  if (text.empty()) {
    return std::string();
  }
  const int size = WideCharToMultiByte(CP_UTF8, 0, text.c_str(),
                                        static_cast<int>(text.size()), nullptr,
                                        0, nullptr, nullptr);
  if (size <= 0) {
    return std::string();
  }
  std::string result(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()),
                      result.data(), size, nullptr, nullptr);
  return result;
}

// 从 EncodableMap 里取一个 bool，类型不符时用兜底值。
bool BoolArg(const flutter::EncodableMap* args, const char* key,
             bool fallback) {
  if (args == nullptr) {
    return fallback;
  }
  const auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) {
    return fallback;
  }
  const bool* value = std::get_if<bool>(&it->second);
  return value == nullptr ? fallback : *value;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // -- 桌面通道（托盘 + 显示器变化）------------------------------------------
  // MethodChannel 的拷贝构造被禁掉了，只能就地构造（不能先建临时对象再拷）。
  desktop_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "whalepet/desktop",
          &flutter::StandardMethodCodec::GetInstance());
  desktop_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();
        if (method == "setTrayState") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (tray_) {
            tray_->SetState(BoolArg(args, "visible", true),
                            BoolArg(args, "voiceEnabled", false));
          }
          result->Success();
        } else if (method == "quit") {
          result->Success();
          // Dart 侧已经落盘，这里直接结束消息循环。
          PostQuitMessage(0);
        } else {
          result->NotImplemented();
        }
      });

  // -- 托盘图标 --------------------------------------------------------------
  taskbar_created_message_ = RegisterWindowMessageW(L"TaskbarCreated");
  tray_ = std::make_unique<TrayIcon>(GetHandle(), kTrayCallbackMessage);
  tray_->SetActionHandler(
      [this](const std::wstring& action) { NotifyTrayAction(action); });
  tray_->Add();

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::NotifyDisplayChanged() {
  if (!desktop_channel_) {
    return;
  }
  desktop_channel_->InvokeMethod("displayChanged", nullptr);
}

void FlutterWindow::NotifyTrayAction(const std::wstring& action) {
  if (!desktop_channel_) {
    return;
  }
  desktop_channel_->InvokeMethod(
      "trayAction",
      std::make_unique<flutter::EncodableValue>(
          flutter::EncodableValue(Utf8FromWide(action))));
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  // Explorer 重启后托盘图标会消失，需要重新注册。
  if (taskbar_created_message_ != 0 && message == taskbar_created_message_) {
    if (tray_) {
      tray_->Add();
    }
    return 0;
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;

    case kTrayCallbackMessage:
      if (tray_) {
        tray_->HandleCallback(lparam);
      }
      return 0;

    case WM_DISPLAYCHANGE:
      // 插拔显示器 / 改分辨率：工作区变了，Dart 侧要把窗口夹回可见范围。
      NotifyDisplayChanged();
      break;

    case WM_SETTINGCHANGE:
      // 系统设置变化（工作区、主题、任务栏位置等）同样会影响工作区。
      NotifyDisplayChanged();
      break;

    case WM_DPICHANGED:
      // 窗口被拖到不同缩放的显示器上：Dart 侧缓存的 DPI 比例要刷新。
      NotifyDisplayChanged();
      break;

    default:
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
