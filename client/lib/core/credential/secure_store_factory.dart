/// §2.8 三档存储裁定（ADR-012）。
///
/// H 可用 → [HardwareSecureStore]；否则经 [confirmSoftwareFallback] 选 S 或 M。
/// 🔒 红线 #1 承重路径。
library;

import 'blob_store.dart';
import 'hardware_keystore.dart';
import 'hardware_secure_store.dart';
import 'secure_store.dart';
import 'software_secure_store.dart';

/// 按硬件可用性 + 用户知情同意裁定 SecureStore 后端。
Future<SecureStore> resolveSecureStore({
  required HardwareKeyStore hardware,
  required BlobStore blobs,
  required Future<bool> Function() confirmSoftwareFallback,
}) async {
  if (await hardware.isAvailable()) {
    return HardwareSecureStore.open(hardware, blobs);
  }
  if (await confirmSoftwareFallback()) {
    return SoftwareSecureStore.open(blobs);
  }
  return InMemorySecureStore(releaseMode: false);
}
