/// Android / 未来平台 MethodChannel 实现 [HardwareKeyStore]（ADR-012 §2.8 H 档）。
///
/// 通道名 `elecon/keystore`；原生侧私钥/KEK 永不出硬件。
/// 🔒 红线 #1 承重路径。须人工 + 安全清单审，不得 AI 独自闭环合并。
library;

import 'package:flutter/services.dart';

import 'hardware_keystore.dart';

const MethodChannel _channel = MethodChannel('elecon/keystore');

/// 经平台通道调用 Android Keystore（StrongBox→TEE）等后端。
class BackedHardwareKeyStore implements HardwareKeyStore {
  const BackedHardwareKeyStore();

  @override
  Future<bool> isAvailable() async {
    try {
      final v = await _channel.invokeMethod<bool>('isHardwareAvailable');
      return v == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<Uint8List> wrapDek(List<int> dek) async {
    final raw = await _channel.invokeMethod<Uint8List>(
      'wrapDek',
      Uint8List.fromList(dek),
    );
    if (raw == null) {
      throw StateError('wrapDek 返回 null');
    }
    return raw;
  }

  @override
  Future<Uint8List> unwrapDek(List<int> wrapped) async {
    final raw = await _channel.invokeMethod<Uint8List>(
      'unwrapDek',
      Uint8List.fromList(wrapped),
    );
    if (raw == null) {
      throw StateError('unwrapDek 返回 null');
    }
    return raw;
  }
}
