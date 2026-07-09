/// 硬件密钥库端口（ADR-012 §2.8 H 硬件档的 KEK 包裹接口）。
///
/// H 硬件档：DEK 由硬件 KEK 包裹（wrap），KEK 私钥/对称密钥**永不出硬件**，
/// unwrap 须硬件参与。真实实现 = Android Keystore / iOS Secure Enclave 平台通道，
/// 是**后续人工主导 PR**（红线 #1，需真机测试）；本文件只定端口 + 未接入占位。
library;

import 'dart:typed_data';

abstract interface class HardwareKeyStore {
  /// 设备是否有可用的硬件加密方案。false → 落 §2.8 的 S/M 档（经用户知情同意）。
  Future<bool> isAvailable();

  /// 用硬件 KEK 包裹 DEK（H 档）。私钥不出硬件。
  Future<Uint8List> wrapDek(List<int> dek);

  /// 用硬件 KEK 解包 DEK（H 档），须硬件参与。
  Future<Uint8List> unwrapDek(List<int> wrapped);
}

/// 未接入占位：硬件档尚未落地——检测恒不可用，wrap/unwrap 抛错。
/// 现阶段全设备据此落到 S 软件档 / M 内存档（§2.8）。
class UnavailableHardwareKeyStore implements HardwareKeyStore {
  const UnavailableHardwareKeyStore();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<Uint8List> wrapDek(List<int> dek) async =>
      throw UnsupportedError('H 硬件档未接入（ADR-012 §2.8，后续人工主导 PR）');

  @override
  Future<Uint8List> unwrapDek(List<int> wrapped) async =>
      throw UnsupportedError('H 硬件档未接入（ADR-012 §2.8，后续人工主导 PR）');
}
