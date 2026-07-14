# H 硬件档与持久化接线设计草案（keystore implementation plan）

> 状态：**大部已落地（2026-07-14 更新）**。原为 AI 起草的实现计划；H 硬件档、持久化落盘、备份排除
> 已按本计划实现并入库（提交 `9f1825e` hardware encryption / `2012e21` iOS SE），经人工 + 安全清单审。
> 下方 §1–§4 保留为**设计依据 / 历史记录**；当前事实以「现况梗概」表与代码为准。剩余勾稽见 §5。
> 关联：ADR-012 §2.7/§2.8、`secure_store_factory.dart`、`hardware_secure_store.dart`、`hardware_keystore_channel.dart`。

## 现况梗概（2026-07-14）

| 组件 | 现状 | 备注 |
|---|---|---|
| H 硬件档 | **已实现**：`BackedHardwareKeyStore`（MethodChannel `elecon/keystore`）+ `HardwareSecureStore`（§2.8 信封 AES-256-GCM + KEK wrap/unwrap）；iOS Secure Enclave / Android Keystore 原生插件已入库 | `secure_store_factory` 已接线 `HardwareSecureStore.open` |
| S 软件档 | **已实现 + 真实落盘集成**：`SoftwareSecureStore` + `FileBlobStore` | path_provider 阻塞已解除 |
| M 内存档 | `InMemorySecureStore` 已实现 | 硬件不可用 + 用户拒 S 档时的兜底 |
| 持久化 | **已点亮**：`_blobStoreProvider` 经 `getApplicationSupportDirectory()/credentials` 接 `FileBlobStore` | 见 `main.dart` |
| 备份排除 | **已实现**：Android `allowBackup=false` + `dataExtractionRules`/`fullBackupContent` 排除 credentials；iOS `BackupExcludePlugin`（`isExcludedFromBackup`）| 提交 `2012e21` |

## 1. H 硬件档实现

### 1.1 接口不变

当前 `HardwareKeyStore` 接口（`hardware_keystore.dart:10-18`）是 AWS KMS 式「用 KEK wrap/unwrap DEK」的语义——适配信封加密（ADR-012 §2.8）。这个接口**保持**——平台差异在实现侧。

### 1.2 各平台实现

#### iOS / macOS（Keychain + Secure Enclave）

- **检测**：尝试生成一个 Secure Enclave 背书的 256 位对称 key（`kSecAttrTokenIDSecureEnclave` + `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`），成功即 H 档可用。
- **wrap**：用 Keychain 里的 KEK（`SecKeyCreateEncryptedData` / `SecKeyCreateDecryptedData`，即 SE 加密/解密任意 blob）——不是用 DEK 加密数据，而是用 SE 密钥**加密 DEK** 本身。DEK 仍是纯软件 AES-256 密钥。
- 或者**更简**：直接存 DEK 于 Keychain `kSecClassGenericPassword`——此时不需要 wrap/unwrap，Keychain 本身已做 at-rest 加密，SE 密钥是 Keychain 的类密钥。这条路径等价于 ADR-012 §2.7 决策 C（"直存 OS secure storage，app 不自持长期密钥"），但不符合 §2.8 的"KEK wrap DEK"三档信封模型——需要权衡。

**建议**：H 档走「软件 DEK 由 Keychain-stored SE-backed 对称密钥包裹」——满足 §2.8 信封模型（`protection: hardware, wrapped: true`），SE 参与 unwrap。平台后端选 `keychain-secure-enclave`。

#### Android（Keystore）

- **检测**：`KeyGenParameterSpec.Builder(...).setUserAuthenticationRequired(false).setIsStrongBoxBacked(true)`——若 StrongBox 不可用，退到 TEE-backed 而非 StrongBox（`setIsStrongBoxBacked(false)` 即 TEE/软件 fallback，仍是硬件档，文档注明"non-StrongBox TEE"）。若连 TEE 都无 → H 不可用，落 S/M。
- **wrap**：`Cipher.wrap(dek)` / `Cipher.unwrap(wrapped, "AES", Cipher.SECRET_KEY)`（Android Keystore `WRAP_KEY` purpose），DEK 是纯软件 `KeyGenerator.getInstance("AES")` 生成的 256-bit `SecretKey`，由 Android Keystore 的公钥/对称 KEK 包裹。
- 平台后端选 `android-keystore-strongbox` / `android-keystore-tee`。

#### Windows（DPAPI）

- **检测**：`CryptProtectData(nullptr, ...)` 调用成功 → 可用。
- **wrap**：DEK 经 `CryptProtectData` 加密（`CRYPTPROTECT_LOCAL_MACHINE` / user scope），产出 opaque blob。DPAPI 密钥由 OS 用户登录密钥保护，非硬件但比纯软件加密强（密钥不出 OS 密钥隔离区）——标注为"DPAPI（OS 认证）"而非"硬件备份"。
- 平台后端选 `windows-dpapi`。

#### Linux / 桌面（Secret Service）

- 非硬件加密——走现有的 M/S 通道（UI 询问用户是否接受 S 档）。若未来硬件支持（TPM via libtss2），另起 PR。

### 1.3 统一后端（Dart 侧）

```dart
// 新增 client/lib/core/credential/hardware_keystore_impl.dart 🔒 人工主导
class BackedHardwareKeyStore implements HardwareKeyStore {
  // 平台通道：MethodChannel('elecon/keystore')
  @override
  Future<bool> isAvailable() async => channel.invokeMethod('isHardwareAvailable');
  @override
  Future<Uint8List> wrapDek(List<int> dek) async => channel.invokeMethod('wrapDek', dek);
  @override
  Future<Uint8List> unwrapDek(List<int> wrapped) async => channel.invokeMethod('unwrapDek', wrapped);
}
```

各平台侧用原生代码实现上述 MethodChannel 回调（Kotlin/Swift/ObjC/C++）。**每平台实现均须人工 + 安全清单审，不可 AI 独自闭环**。

### 1.4 secure_store_factory.dart 接线

```diff
   if (await hardware.isAvailable()) {
-    // TODO(§2.8 H 硬件档，人工主导 PR）
-    throw UnimplementedError('H 硬件档未接入');
+    return HardwareSecureStore.open(hardware, blobs);
   }
```

`HardwareSecureStore` 对 `CredentialEntry.value` 的加密沿用 §2.8 信封：
1. 生成随机 DEK（AES-256，`Random.secure()`），对 value 做 AES-256-GCM AEAD（复用 `SoftwareSecureStore` 的加密原语，cryptography ^2.6.x）。
2. 用 `hardware.wrapDek(dek)` 包裹 DEK → `wrappedDek`。
3. 落盘：`{ iv, tag, ciphertext, wrappedDek, protection: "hardware", wrapped: true }`。

---

## 2. 持久化接线（path_provider + FileBlobStore）

参见 `build_unblock_plan.md` PR-A2：
- **前提**：vendoring flutter_qjs（解 pub git fetch 挂起）→ `pub add path_provider` → `main.dart` 点亮 `FileBlobStore`。
- **命门**：Android `allowBackup=false` + 从 auto-backup 排除；iOS `isExcludedFromBackup`（ADR-012 风险条 10）。须在**同一 PR 同时实现**。
- **备份排除清单**（每个平台 android/app/src/main/AndroidManifest.xml + ios/Runner/Info.plist 各一条，🔒 安全清单必检）：
  - Android：`<application android:allowBackup="false" ...>` + 若使用 `android:fullBackupContent` 则显式排 credential 目录。
  - iOS：`FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])` + `isExcludedFromBackup`。

---

## 3. 测试矩阵（大纲，人工编写或实质审阅，testing.md）

| 档 | 测试 | 关键词 |
|---|---|---|
| H | DEK wrap/unwrap 往返、H→S 退级、SE 不可用时的正确拒 | `HardwareSecureStore` |
| S | AEAD 加解密往返、FileBlobStore flush/load、备份排除**集成**（真机） | `SoftwareSecureStore` + `FileBlobStore` |
| M | 内存-only、跨进程重启凭证丢失（预期行为） | `InMemorySecureStore` |
| 分级 | 实际设备上 H→S/M 自动检测 + UI 警告框流程 | e2e |

---

## 4. PR 拆分建议（ADT-012 落地清单补项，每 PR 可独立审查/回滚）

1. **PR-H1**：`BackedHardwareKeyStore` 端口（Dart MethodChannel）+ iOS `hardware_keystore_impl` 🔒
2. **PR-H2**：Android `hardware_keystore_impl`（StrongBox→TEE fallback）🔒
3. **PR-H3**：`HardwareSecureStore` 信封加密（AES-256-GCM + KEK wrap/unwrap）🔒
4. **PR-H4**：`secure_store_factory.dart` 接线 + H 档激活 🔒
5. **PR-P1**：path_provider + FileBlobStore（前提：vendoring 已合，build_unblock_plan PR-A1）🔒
6. **PR-P2**：备份排除（Android `allowBackup=false` + iOS `isExcludedFromBackup`）🔒

---

## 5. 收尾待办

- [x] H 硬件档各平台实现（PR-H1–H4）🔒 —— iOS SE / Android Keystore 已入库（`9f1825e` / `2012e21`）
- [x] path_provider + FileBlobStore 接线（PR-P1）🔒
- [x] 备份排除（PR-P2）🔒 —— Android `allowBackup=false` + iOS `BackupExcludePlugin`
- [ ] 登出抹除 / 过期 / S 软件档 UI 持续警示在各真实后端（含 H 档）的一致性行为测试
- [ ] iOS App Store 合规自检（ADR-010 §3.3）——Keychain / Secure Enclave 使用需在隐私申报中声明
