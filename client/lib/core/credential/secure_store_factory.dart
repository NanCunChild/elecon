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

  // M 内存档（= §2.7 决策 E 旧 fail-closed 行为，但现在是用户主动选择）。
  // 🔒 待人工评审：M 档复用 InMemorySecureStore；其 release 守卫（§2.7 决策 F 禁明文
  // 内存后端）语义需与「M 档是 §2.8 知情同意后的合法选项」协调——当前 dev/debug 无冲突，
  // release 下二者关系须在 wiring PR 里定，不在本 draft 擅自放宽护栏。
  return InMemorySecureStore(releaseMode: false);
}
