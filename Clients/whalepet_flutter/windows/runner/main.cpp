#include <dwmapi.h>
#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

#pragma comment(lib, "dwmapi.lib")

namespace {

// 桌宠窗口样式（docs/CROSS_PLATFORM.md §10.3）：
//   - 去掉标题栏/边框，且不进任务栏与 Alt+Tab（WS_EX_TOOLWINDOW）；
//   - WS_EX_LAYERED + 整窗 alpha=255：让 DWM 按渲染表面的 alpha 合成，
//     宠物周围的透明区域才能真正透出桌面；
//   - DwmExtendFrameIntoClientArea(-1)：把整块客户区并入「玻璃」，
//     否则未绘制区域会被系统刷成不透明底色；
//   - 置顶，避免被普通窗口压住。
//
// 说明：这里只做「窗口层」的透明，逐像素 alpha 来自 Flutter 的渲染表面；
// 鼠标是否吃事件由 Dart 侧 Win32DesktopWindow.setClickThrough 动态控制。
void ConfigurePetWindow(HWND hwnd) {
  LONG_PTR style = ::GetWindowLongPtr(hwnd, GWL_STYLE);
  style &= ~(WS_CAPTION | WS_THICKFRAME | WS_SYSMENU | WS_MINIMIZEBOX |
             WS_MAXIMIZEBOX);
  ::SetWindowLongPtr(hwnd, GWL_STYLE, style);

  LONG_PTR ex_style = ::GetWindowLongPtr(hwnd, GWL_EXSTYLE);
  ex_style |= (WS_EX_TOOLWINDOW | WS_EX_LAYERED | WS_EX_TOPMOST);
  ::SetWindowLongPtr(hwnd, GWL_EXSTYLE, ex_style);

  ::SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA);

  MARGINS margins = {-1, -1, -1, -1};
  ::DwmExtendFrameIntoClientArea(hwnd, &margins);

  ::SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED | SWP_SHOWWINDOW);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // 初始尺寸与 Dart 侧 PetLayout.windowWidth/Height 一致（逻辑像素），
  // 避免启动瞬间先闪一个大白窗。
  Win32Window::Point origin(100, 100);
  Win32Window::Size size(380, 560);
  if (!window.Create(L"whalepet_flutter", origin, size)) {
    return EXIT_FAILURE;
  }
  ConfigurePetWindow(window.GetHandle());
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
