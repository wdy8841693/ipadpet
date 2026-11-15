import 'dart:io';

/// 客户端的本地路径约定。
///
/// Windows：`%APPDATA%\WhalePet\`；其它平台（仅开发/测试）回落 `~/.whalepet/`。
/// 目录结构：
/// ```text
/// WhalePet/
/// ├── settings.json     # 窗口位置、服务地址、开关（明文，可读）
/// ├── token.bin         # Bearer 令牌（DPAPI 密文）
/// ├── client_id.txt     # 本机客户端 id（§8.2，不可与 request_id 混用）
/// ├── save/pet_save.json# 宠物数值存档
/// └── logs/             # 预留
/// ```
class AppPaths {
  AppPaths({required this.rootDirectory});

  final Directory rootDirectory;

  File get settingsFile => File(_join(rootDirectory, 'settings.json'));

  File get tokenFile => File(_join(rootDirectory, 'token.bin'));

  File get clientIdFile => File(_join(rootDirectory, 'client_id.txt'));

  Directory get saveDirectory => Directory(_join(rootDirectory, 'save'));

  static String _join(Directory dir, String name) =>
      '${dir.path}${Platform.pathSeparator}$name';

  /// 解析路径（只做路径，不创建目录）。
  static AppPaths resolve({Map<String, String>? environment}) {
    final Map<String, String> env = environment ?? Platform.environment;
    final String? appData = env['APPDATA'];
    if (Platform.isWindows && appData != null && appData.isNotEmpty) {
      return AppPaths(rootDirectory: Directory(_joinString(appData, 'WhalePet')));
    }
    final String? home = env['HOME'] ?? env['USERPROFILE'];
    final String base = home == null || home.isEmpty ? Directory.current.path : home;
    return AppPaths(rootDirectory: Directory(_joinString(base, '.whalepet')));
  }

  static String _joinString(String base, String name) =>
      '$base${Platform.pathSeparator}$name';

  /// 确保目录存在。
  Future<void> ensureCreated() async {
    if (!await rootDirectory.exists()) {
      await rootDirectory.create(recursive: true);
    }
  }
}
