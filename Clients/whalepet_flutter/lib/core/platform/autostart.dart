/// 开机自启适配层（§10.3「托盘和开机启动」）。
///
/// 语义只做一件事：把「开机后自动启动桌宠」这一状态写进系统启动项。
/// 具体落在哪个系统位置由平台实现决定（Windows 是注册表 Run 项）。
abstract interface class AutostartController {
  /// 当前是否已登记开机自启。
  Future<bool> isEnabled();

  /// 设置开机自启；返回设置之后的状态（失败时返回 false）。
  Future<bool> setEnabled(bool enabled);
}

/// 不支持开机自启的平台用的空实现。
class NoopAutostart implements AutostartController {
  const NoopAutostart();

  @override
  Future<bool> isEnabled() async => false;

  @override
  Future<bool> setEnabled(bool enabled) async => false;
}
