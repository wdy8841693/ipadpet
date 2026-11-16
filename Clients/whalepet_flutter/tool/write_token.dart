// 开发小工具：把令牌用 DPAPI 加密写进本地存储，方便验证「令牌安全存储」链路。
//
// 用法：
//   dart run tool/write_token.dart <token>
//
// 正常用户不需要跑它 —— App 的设置面板会写入同样的文件。

import 'dart:io';

import '../lib/core/config/app_paths.dart';
import '../lib/core/config/token_store.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('用法: dart run tool/write_token.dart <token>');
    exitCode = 64;
    return;
  }
  final AppPaths paths = AppPaths.resolve();
  await paths.ensureCreated();
  final TokenStore store = TokenStore(file: paths.tokenFile);
  await store.write(args.first);
  final String? readBack = await store.read();
  print('written: ${paths.tokenFile.path}');
  print('read back: ${readBack == args.first ? 'OK（DPAPI 往返成功）' : 'FAILED（$readBack）'}');
}
