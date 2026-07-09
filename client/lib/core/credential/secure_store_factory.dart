/// 三档 store 选择（ADR-012 §2.8）：H 硬件档 / S 软件档 / M 内存档。
///
/// 决策流：硬件可用 → H 硬件档（未接入）；否则由用户知情同意（[confirmSoftwareFallback]，
/// 通常来自 §2.8 警告框）选 S 软件档持久化或 M 内存档（取消 = fail toward less trust）。
///
/// 🔒 红线 #1。AI 起草、经人工审阅接受（2026-07-09）；后续改动仍须人工 + 安全清单审（AGENTS.md §1）。
library;

import 'blob_store.dart';
import 'hardware_keystore.dart';
import 'secure_store.dart';
import 'software_secure_store.dart';

/// 返回按 §2.8 三档裁定的 [SecureStore]。
/// [confirmSoftwareFallback]：true=继续（S 软件档持久化），false=取消（M 内存档）。
Future<SecureStore> resolveSecureStore({
  required HardwareKeyStore hardware,
  required BlobStore blobs,
  required Future<bool> Function() confirmSoftwareFallback,
}) async {
  if (await hardware.isAvailable()) {
    // TODO(§2.8 H 硬件档，人工主导 PR）：return HardwareSecureStore.open(hardware, blobs);
    throw UnimplementedError('H 硬件档未接入（ADR-012 §2.8）');
  }

  final continueSoftware = await confirmSoftwareFallback();
  if (continueSoftware) {
    return SoftwareSecureStore.open(blobs); // S 软件档
  }

  // M 内存档（= §2.7 决策 E 旧 fail-closed 行为，但现在是用户**主动知情同意**的选择）。
  // 护栏协调（§2.7 决策 F ↔ §2.8 M 档）：决策 F 禁的是「省略 store 时**静默默认**明文内存
  // 后端」；这里是经 confirmSoftwareFallback 显式取得用户同意后的**授权**内存档，属决策 F
  // 允许的「显式注入」路径，故传 releaseMode:false 明确授权，与护栏不冲突（授权 vs 静默默认）。
  return InMemorySecureStore(releaseMode: false);
}
