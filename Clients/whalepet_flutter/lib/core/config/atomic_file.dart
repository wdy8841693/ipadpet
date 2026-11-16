import 'dart:io';

/// 原子写文本文件。
///
/// 规则来源：`docs/CROSS_PLATFORM.md` §11.1「原子写入」。
///
/// POSIX 上 `rename` 会在目标存在时原子替换；**Windows 上目标存在时 rename 会抛
/// FileSystemException**，所以这里退化为「先删后改名」，并保证不残留 `.tmp`。
/// 这修掉了阶段 B README 里记录的 Windows 风险点。
Future<void> writeFileAtomically(File target, String contents) async {
  final Directory parent = target.parent;
  if (!await parent.exists()) {
    await parent.create(recursive: true);
  }
  final File temp = File('${target.path}.tmp');
  await temp.writeAsString(contents, flush: true);
  try {
    await temp.rename(target.path);
    return;
  } on FileSystemException {
    if (!await target.exists()) rethrow;
  }
  // Windows：目标已存在，先删再改名。
  await target.delete();
  await temp.rename(target.path);
}
