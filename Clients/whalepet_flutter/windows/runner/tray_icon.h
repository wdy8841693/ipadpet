#ifndef RUNNER_TRAY_ICON_H_
#define RUNNER_TRAY_ICON_H_

#include <windows.h>

#include <functional>
#include <string>

// 托盘图标（docs/CROSS_PLATFORM.md §10.3「处理置顶、无任务栏图标、托盘和开机启动」）。
//
// 桌宠主窗口带 WS_EX_TOOLWINDOW（不在任务栏、不进 Alt+Tab），所以一旦把窗口
// 隐藏起来，用户就再也找不到它 —— 托盘是这个闭环里唯一的「找回入口」。
//
// 实现要点：
//   - NOTIFYICONDATA 挂在主窗口 HWND 上，回调消息走窗口消息队列；
//   - 右键弹菜单（TPM_RETURNCMD 直接拿命令号，不必绕 WM_COMMAND）；
//   - Explorer 重启后托盘图标会掉，注册 WM_TASKBARCREATED 收到后重新 Add；
//   - 菜单动作（显示/隐藏、语音开关、设置、退出）通过回调抛给 FlutterWindow，
//     由它转成 MethodChannel 事件给 Dart，窗口逻辑仍然只有 Dart 一份。
class TrayIcon {
 public:
  using ActionHandler = std::function<void(const std::wstring&)>;

  TrayIcon(HWND owner, UINT callback_message);
  ~TrayIcon();

  // 注册图标到托盘；失败返回 false（不影响主功能）。
  bool Add();

  // 从托盘移除。
  void Remove();

  // 菜单状态：窗口是否可见、语音唤醒是否开启（决定菜单文案与勾选）。
  void SetState(bool visible, bool voice_enabled);

  // 处理托盘回调消息，lparam 是鼠标事件（WM_RBUTTONUP / WM_LBUTTONDBLCLK 等）。
  void HandleCallback(LPARAM lparam);

  void SetActionHandler(ActionHandler handler);

 private:
  void ShowContextMenu();
  void UpdateTooltip();

  HWND owner_ = nullptr;
  UINT callback_message_ = 0;
  NOTIFYICONDATAW data_{};
  bool added_ = false;
  bool visible_ = true;
  bool voice_enabled_ = false;
  ActionHandler action_handler_;
};

#endif  // RUNNER_TRAY_ICON_H_
