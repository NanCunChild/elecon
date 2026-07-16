# 构建/依赖阻塞情况说明（build blockers）

> 状态记录，非 ADR。记录当前卡住工具链升级与依赖更新的几个相互纠缠的问题，供后续处理时参考。
> 最后更新：2026-07-16。

## TL;DR

| 阻塞 | 现状 | 根因 | 影响 |
|---|---|---|---|
| **AGP 版本** | 已修到 8.11.1 | 曾降到 8.9.2（< Flutter 下限）| 已解决（清除弃用警告）|
| **flutter_qjs 停更 fork** | 已迁 `flutter_qjs_next` pub.dev `1.0.2` | 上游 ekibun 停更 | 主线已解除 ffi/KGP/Java 兼容阻塞 |
| **cryptography 版本** | 已升 2.9.0 | `flutter_qjs_next` 已解除 ffi 冲突 | 已解决 |
| **path_provider 加不进** | 已加入并接线 | 原 git 依赖阻塞已解除 | 已点亮 §2.8 S 档落盘 |
| **KGP 弃用警告** | 已解决 | `flutter_qjs_next` 不再 apply KGP | Android debug 构建已无该警告 |
| **H 硬件档接入** | 已实现 | iOS SE / Android Keystore 原生插件入库（`9f1825e`/`2012e21`）| §2.8 三档存储 H 档点亮 |
| **release 构建** | 已修复 | `main` manifest 缺 `INTERNET` + 注释含非法 `--`（`345a5fc`）| `--release` 可构建可登录；CI 加 release 构建闸门（`41c14de`）|
| **git/GPG 网络** | 绕行中 | libsecret 凭证助手挂起 | pub git fetch / commit 签名超时 |

---

## 1. AGP（已解决）

- 提交 `3731204` 用 AGP **9.0.1**；工作树一度降到 **8.9.2**（+ 给 flutter_qjs 加 Java 11 兼容）。
- 8.9.2 **低于** Flutter 3.44 的 AGP 下限 **8.11.1** → 每次构建「will soon be dropped」弃用警告，且未来 Flutter 升级会 fail。
- **处理（提交 `42b79a4`）**：升到 **8.11.1**——实测构建通过、警告消除，仍留 8.x 避开 AGP 9.0.x 对 flutter_qjs 的 Kotlin/Java 兼容坑。
- **暂不上 AGP 9.0.x**：会重新触发导致当初降级的兼容问题；待 flutter_qjs 适配后再评估。

## 2. QuickJS 绑定迁移（已处理主线）

主线已从 `flutter_qjs`（ekibun 补丁 fork）迁到 pub.dev 精确版本
`flutter_qjs_next: 1.0.2`（上游 `https://github.com/NanCunChild/flutter_qjs_next`，MIT）。它是 QuickJS
承重依赖（ADR-008/014），迁移后解除原先纠缠：

- `ffi` 已升到 2.2.0，`cryptography` 冲突已解除并**已升到 2.9.0**（`pubspec.yaml: cryptography: ^2.9.0`）。
- Android 插件不再 apply Kotlin Gradle Plugin，`flutter build apk --debug` 已无 KGP 未来失败警告。
- root `build.gradle.kts` 中旧 `flutter_qjs` Java/Kotlin 强钉补丁已移除。

注意：`pubspec.ohos.yaml` 仍保留旧 `flutter_qjs` 旁路线，OHOS fork 需单独验证。

## 3. path_provider（已接入，§2.8 S 档落盘已点亮）

- ADR-012 §2.8 的 **S 软件档**需要 app 私有目录落盘；现已加入 `path_provider`，`main.dart` 通过
  `getApplicationSupportDirectory()/credentials` 接到 `FileBlobStore`。
- Android 已同步配置 `allowBackup=false`、`fullBackupContent` 与 `dataExtractionRules`，排除 credentials 目录，避免 S 档 DEK 随系统备份外泄。
- **H 硬件档已接入**（提交 `9f1825e` / `2012e21`）：`BackedHardwareKeyStore`（MethodChannel `elecon/keystore`）+ `HardwareSecureStore` 信封加密；iOS Secure Enclave / Android Keystore 原生插件入库，`secure_store_factory` 已接线。详见 `hardware_persistence_plan.md`。

## 4. QuickJS 依赖复现性

当前用 pub.dev hosted 依赖接入 `flutter_qjs_next: 1.0.2`，`pubspec.lock` 固定 SHA-256。
测试脚本从 package config 定位包，清理复制的构建缓存，并兼容发布包缺少 example 的情况。

## 5. git / GPG 网络（libsecret 挂起）

- 会话环境里 `git` 的网络命令（fetch/push）与 pub 的 git 依赖 fetch 经 **libsecret** 凭证助手**挂起**（`credential.helper=libsecret`）。
- **GPG 签名**同源问题：pinentry 缓存过期后 `commit -S` 超时；本轮提交先 `--no-gpg-sign`，待人工 rebase 补签。
- **绕行**：远程状态用 `gh api`；已有依赖用 `flutter pub get --offline`；判断分叉先 `gh` 核对而非 `git fetch`。

---

## 待办（人工主导）

- [x] 主线迁 `flutter_qjs_next`：解除 KGP 警告 + ffi 1.x 冲突。
- [x] 将 `flutter_qjs_next` 从 Git commit pin 收敛到 pub.dev `1.0.2`，并固定 hosted SHA-256。
- [x] 单独升级 cryptography 到 2.9.x。
- [x] 加 path_provider，点亮 §2.8 S 档落盘 + `allowBackup=false` / 备份排除。
- [ ] 环境 libsecret / pinentry 修复，恢复正常 git/GPG。
- [ ] 本分支 `--no-gpg-sign` 提交待 rebase 补签。
