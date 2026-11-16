#include "tray_icon.h"

#include "resource.h"

namespace {

constexpr UINT kTrayIconId = 1;

// 菜单命令号（只在 runner 内部使用，跨进程边界给 Dart 的是字符串动作名）。
constexpr UINT kCmdToggleVisible = 1001;
constexpr UINT kCmdToggleVoice = 1002;
constexpr UINT kCmdSettings = 1003;
constexpr UINT kCmdQuit = 1004;

// 动作名 -> Dart 侧 DesktopTrayAction。
constexpr const wchar_t kActionToggleVisible[] = L"toggleVisible";
constexpr const wchar_t kActionToggleVoice[] = L"toggleVoice";
constexpr const wchar_t kActionSettings[] = L"openSettings";
constexpr const wchar_t kActionQuit[] = L"quit";

}  // namespace

TrayIcon::TrayIcon(HWND owner, UINT callback_message)
    : owner_(owner), callback_message_(callback_message) {
  data_ = {};
  data_.cbSize = sizeof(NOTIFYICONDATAW);
  data_.hWnd = owner_;
  data_.uID = kTrayIconId;
  data_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  data_.uCallbackMessage = callback_message_;
  data_.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  UpdateTooltip();
}

TrayIcon::~TrayIcon() {
  Remove();
}

bool TrayIcon::Add() {
  if (owner_ == nullptr) {
    return false;
  }
  if (Shell_NotifyIconW(NIM_ADD, &data_) == FALSE) {
    return false;
  }
  added_ = true;
  return true;
}

void TrayIcon::Remove() {
  if (!added_) {
    return;
  }
  Shell_NotifyIconW(NIM_DELETE, &data_);
  added_ = false;
}

void TrayIcon::SetState(bool visible, bool voice_enabled) {
  visible_ = visible;
  voice_enabled_ = voice_enabled;
  UpdateTooltip();
  if (!added_) {
    return;
  }
  // 只改提示气泡；菜单文案在弹出时现算。
  NOTIFYICONDATAW update = data_;
  update.uFlags = NIF_TIP;
  Shell_NotifyIconW(NIM_MODIFY, &update);
}

void TrayIcon::SetActionHandler(ActionHandler handler) {
  action_handler_ = std::move(handler);
}

void TrayIcon::UpdateTooltip() {
  std::wstring tip = L"WhalePet 桌宠";
  tip += visible_ ? L"" : L"（已隐藏）";
  tip += voice_enabled_ ? L" · 语音唤醒开" : L"";
  // wcscpy_s 的目标是定长数组，长度必须留结尾的 L'\0'。
  wcsncpy_s(data_.szTip, tip.c_str(), _TRUNCATE);
}

void TrayIcon::HandleCallback(LPARAM lparam) {
  switch (lparam) {
    case WM_RBUTTONUP:
    case WM_CONTEXTMENU:
      ShowContextMenu();
      break;
    case WM_LBUTTONDBLCLK:
      if (action_handler_) {
        action_handler_(kActionToggleVisible);
      }
      break;
    default:
      break;
  }
}

void TrayIcon::ShowContextMenu() {
  if (owner_ == nullptr) {
    return;
  }
  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }
  AppendMenuW(menu, MF_STRING, kCmdToggleVisible,
              visible_ ? L"隐藏宠物" : L"显示宠物");
  AppendMenuW(menu, MF_STRING | (voice_enabled_ ? MF_CHECKED : MF_UNCHECKED),
              kCmdToggleVoice, L"语音唤醒");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kCmdSettings, L"设置…");
  AppendMenuW(menu, MF_STRING, kCmdQuit, L"退出");

  POINT cursor{};
  GetCursorPos(&cursor);
  // 菜单弹出前把窗口置前，否则点击别处时菜单不会自动消失。
  SetForegroundWindow(owner_);
  const UINT command = TrackPopupMenuEx(
      menu, TPM_RIGHTBUTTON | TPM_RETURNCMD, cursor.x, cursor.y, owner_,
      nullptr);
  PostMessage(owner_, WM_NULL, 0, 0);
  DestroyMenu(menu);

  if (command == 0 || !action_handler_) {
    return;
  }
  switch (command) {
    case kCmdToggleVisible:
      action_handler_(kActionToggleVisible);
      break;
    case kCmdToggleVoice:
      action_handler_(kActionToggleVoice);
      break;
    case kCmdSettings:
      action_handler_(kActionSettings);
      break;
    case kCmdQuit:
      action_handler_(kActionQuit);
      break;
    default:
      break;
  }
}
