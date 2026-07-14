/// 字节持久化后端（ADR-012 §2.8 落盘抽象）。
///
/// 把 store 逻辑与「落哪」解耦：真实 = app 私有目录文件（[FileBlobStore]，目录由
/// wiring 层用 path_provider 提供）；测试 = 内存（[InMemoryBlobStore]）。
/// 这样 [SoftwareSecureStore] 的加解密逻辑可脱离平台插件单测。
library;

import 'dart:io';

import 'package:flutter/services.dart';

abstract interface class BlobStore {
  Future<Uint8List?> read(String name);
  Future<void> write(String name, List<int> bytes);
  Future<void> delete(String name);
}

/// 真实后端：app 私有目录下的文件（§2.8：Android getFilesDir 等私有目录）。
/// [directory] 由 wiring 层用 path_provider 的 application support 目录提供。
/// 🔒 §2.8 命门：该目录须配 `allowBackup=false` / 备份排除，否则明文 DEK 随备份外泄。
class FileBlobStore implements BlobStore {
  FileBlobStore(this.directory);

  final Directory directory;

  File _file(String name) => File('${directory.path}/$name');

  @override
  Future<Uint8List?> read(String name) async {
    final f = _file(name);
    if (!await f.exists()) return null;
    return f.readAsBytes();
  }

  @override
  Future<void> write(String name, List<int> bytes) async {
    final f = _file(name);
    await f.parent.create(recursive: true);
    // 先写临时文件再原子 rename，避免半写损坏整库。
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(f.path);
  }

  @override
  Future<void> delete(String name) async {
    final f = _file(name);
    if (await f.exists()) await f.delete();
  }

  /// 创建目录并标记系统备份排除（iOS isExcludedFromBackup / Android 已 allowBackup=false）。
  /// 失败吞掉：不得阻断凭证路径。
  Future<void> ensureDirectoryAndExcludeFromBackup() async {
    await directory.create(recursive: true);
    try {
      await const MethodChannel('elecon/backup')
          .invokeMethod<void>('excludeFromBackup', directory.path);
    } on MissingPluginException {
      // 桌面/测试无插件
    } on PlatformException {
      // 非致命
    }
  }
}

/// 测试后端：内存 Map。
class InMemoryBlobStore implements BlobStore {
  final Map<String, Uint8List> _blobs = {};

  @override
  Future<Uint8List?> read(String name) async => _blobs[name];

  @override
  Future<void> write(String name, List<int> bytes) async =>
      _blobs[name] = Uint8List.fromList(bytes);

  @override
  Future<void> delete(String name) async => _blobs.remove(name);
}
