import 'dart:io';

import 'package:test/test.dart';
import 'package:whalepet_flutter/core/pet/pet_vitals.dart';
import 'package:whalepet_flutter/core/storage/pet_save.dart';
import 'package:whalepet_flutter/core/storage/pet_save_store.dart';

void main() {
  late Directory tempDir;
  late PetSaveStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('whalepet-save-test-');
    store = PetSaveStore(directory: tempDir);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('文件不存在时返回默认存档', () async {
    final PetSave save = await store.load();
    expect(save.vitals.satiety, 100.0);
    expect(await store.file.exists(), isFalse);
  });

  test('保存后能原样读回（原子写）', () async {
    final PetSave save = PetSave.defaults().copyWith(
      vitals: PetVitals(satiety: 42.0, mood: 55.0, energy: 66.0),
      totalFeeds: 4,
      totalPets: 9,
      petName: '小鲸测试',
    );
    await store.save(save);
    expect(await store.file.exists(), isTrue);
    // .tmp 不应残留。
    expect(await File('${store.file.path}.tmp').exists(), isFalse);

    final PetSave loaded = await store.load();
    expect(loaded.vitals, save.vitals);
    expect(loaded.totalFeeds, 4);
    expect(loaded.totalPets, 9);
    expect(loaded.petName, '小鲸测试');
  });

  test('目录不存在时会自动创建', () async {
    final Directory nested = Directory('${tempDir.path}/a/b/c');
    final PetSaveStore nestedStore = PetSaveStore(directory: nested);
    await nestedStore.save(PetSave.defaults());
    expect(await nestedStore.file.exists(), isTrue);
  });

  test('损坏存档：先备份再回落默认值', () async {
    await store.directory.create(recursive: true);
    await store.file.writeAsString('{坏掉的 JSON');

    final PetSave loaded = await store.load();
    expect(loaded.vitals.satiety, 100.0);
    // 原文件已被移走，留下一个 .corrupt-* 备份。
    expect(await store.file.exists(), isFalse);
    final List<FileSystemEntity> backups = await tempDir
        .list()
        .where((FileSystemEntity entity) => entity.path.contains('.corrupt-'))
        .toList();
    expect(backups.length, 1);
    expect(await File(backups.first.path).readAsString(), '{坏掉的 JSON');
  });

  test('多次损坏会留下多个备份，不会互相覆盖', () async {
    for (int i = 0; i < 2; i += 1) {
      await store.directory.create(recursive: true);
      await store.file.writeAsString('bad-$i');
      await store.load();
      // 让时间戳不同（毫秒级）。
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }
    final List<FileSystemEntity> backups = await tempDir
        .list()
        .where((FileSystemEntity entity) => entity.path.contains('.corrupt-'))
        .toList();
    expect(backups.length, 2);
  });

  test('clear 删除存档但保留备份', () async {
    await store.save(PetSave.defaults());
    await store.directory.create(recursive: true);
    final File backup = File('${store.file.path}.corrupt-1');
    await backup.writeAsString('old');
    await store.clear();
    expect(await store.file.exists(), isFalse);
    expect(await backup.exists(), isTrue);
  });

  test('反复保存不会产生临时文件堆积', () async {
    for (int i = 0; i < 5; i += 1) {
      await store.save(PetSave.defaults().copyWith(totalFeeds: i));
    }
    final List<FileSystemEntity> entries = await tempDir.list().toList();
    expect(entries.length, 1);
    expect((await store.load()).totalFeeds, 4);
  });
}
