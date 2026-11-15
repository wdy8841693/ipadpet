import 'dart:io';

import 'pet_save.dart';

/// 宠物存档的本地持久化。
///
/// 规则来源：docs/CROSS_PLATFORM.md §11.1：
///   - 原子写入（先写 .tmp 再 rename）；
///   - 损坏存档先备份成 `pet_save.json.corrupt-<时间戳>`，再回落到默认值；
///   - 15 秒节流保存、退出或退后台立即保存（节流由上层场景控制器负责）。
class PetSaveStore {
  /// 创建存档仓库。[directory] 是存放存档的目录（不存在会自动创建）。
  PetSaveStore({required this.directory, this.fileName = 'pet_save.json'});

  /// 存档所在目录。
  final Directory directory;

  /// 存档文件名。
  final String fileName;

  /// 存档文件。
  File get file => File('${directory.path}${Platform.pathSeparator}$fileName');

  /// 读取存档。
  ///
  /// 文件不存在 → 返回默认存档；文件损坏 → 先备份再返回默认存档。
  Future<PetSave> load({DateTime? now}) async {
    if (!await file.exists()) {
      return PetSave.defaults(now: now);
    }
    String text;
    try {
      text = await file.readAsString();
    } catch (_) {
      return PetSave.defaults(now: now);
    }
    try {
      return PetSave.decode(text);
    } catch (_) {
      await backupCorrupted();
      return PetSave.defaults(now: now);
    }
  }

  /// 原子写入存档。
  Future<void> save(PetSave save) async {
    await directory.create(recursive: true);
    final File temp = File('${file.path}.tmp');
    await temp.writeAsString(save.encode(), flush: true);
    await temp.rename(file.path);
  }

  /// 删除存档文件（不含备份）。
  Future<void> clear() async {
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// 把损坏的存档备份成 `pet_save.json.corrupt-<毫秒时间戳>`。
  Future<File?> backupCorrupted() async {
    if (!await file.exists()) return null;
    final String stamp = DateTime.now().millisecondsSinceEpoch.toString();
    final File backup = File('${file.path}.corrupt-$stamp');
    try {
      await file.rename(backup.path);
      return backup;
    } catch (_) {
      // 备份失败也不能让调用方崩：直接删掉坏文件。
      try {
        await file.delete();
      } catch (_) {
        // 忽略
      }
      return null;
    }
  }
}
