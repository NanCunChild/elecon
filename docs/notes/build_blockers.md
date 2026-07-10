# 构建/依赖阻塞情况说明（build blockers）

> 状态记录，非 ADR。记录当前卡住工具链升级与依赖更新的几个相互纠缠的问题，供后续处理时参考。
> 最后更新：2026-07-10。

## TL;DR

| 阻塞 | 现状 | 根因 | 影响 |
|---|---|---|---|
| **AGP 版本** | 已修到 8.11.1 | 曾降到 8.9.2（< Flutter 下限）| 已解决（清除弃用警告）|
| **flutter_qjs 停更 fork** | 已迁 `flutter_qjs_next` Git 依赖 | 上游 ekibun 停更 | 主线已解除 ffi/KGP/Java 兼容阻塞 |
| **cryptography 版本** | 仍钉 2.6.x | 迁移后 ffi 冲突已解除 | 可单独 PR 升 2.7+ / 2.9.x |
| **path_provider 加不进** | 未加入 | 原 git 依赖阻塞已解除 | §2.8 落盘仍待单独接线 |
| **KGP 弃用警告** | 已解决 | `flutter_qjs_next` 不再 apply KGP | Android debug 构建已无该警告 |
| **git/GPG 网络** | 绕行中 | libsecret 凭证助手挂起 | pub git fetch / commit 签名超时 |

---

## 1. AGP（已解决）

- 提交 `3731204` 用 AGP **9.0.1**；工作树一度降到 **8.9.2**（+ 给 flutter_qjs 加 Java 11 兼容）。
- 8.9.2 **低于** Flutter 3.44 的 AGP 下限 **8.11.1** → 每次构建「will soon be dropped」弃用警告，且未来 Flutter 升级会 fail。
- **处理（提交 `42b79a4`）**：升到 **8.11.1**——实测构建通过、警告消除，仍留 8.x 避开 AGP 9.0.x 对 flutter_qjs 的 Kotlin/Java 兼容坑。
- **暂不上 AGP 9.0.x**：会重新触发导致当初降级的兼容问题；待 flutter_qjs 适配后再评估。

## 2. QuickJS 绑定迁移（已处理主线）

主线已从 `flutter_qjs`（ekibun 补丁 fork）迁到 Git 依赖
`flutter_qjs_next`（`https://github.com/NanCunChild/flutter_qjs_es2023`）。它是 QuickJS
承重依赖（ADR-008/014），迁移后解除原先纠缠：

- `ffi` 已升到 2.2.0，`cryptography` 2.7+ 的依赖冲突已解除（包版本尚未升级，留单独 PR）。
- Android 插件不再 apply Kotlin Gradle Plugin，`flutter build apk --debug` 已无 KGP 未来失败警告。
- root `build.gradle.kts` 中旧 `flutter_qjs` Java/Kotlin 强钉补丁已移除。

注意：`pubspec.ohos.yaml` 仍保留旧 `flutter_qjs` 旁路线，OHOS fork 需单独验证。

## 3. path_provider 加不进（§2.8 落盘未点亮）

- ADR-012 §2.8 的 **S 软件档**需要 app 私有目录落盘，本应加 `path_provider`。
- 原 `flutter_qjs` git 依赖阻塞已解除；`path_provider` 仍需单独加入并验证。
- **规避（提交 `38b2175`）**：BlobStore 做成**可注入接缝**，`main.dart` 的 provider 暂返回 null → 退化为 **M 内存档**（不落盘）。§2.8 其余流程（硬件检测→警告框→分级→flush）已全部接线并测试。
- **恢复步骤**：网络/依赖恢复后 `flutter pub add path_provider`，在 `main.dart` 把 provider 换成
  `FileBlobStore(Directory('${(await getApplicationSupportDirectory()).path}/credentials'))` 即点亮持久化。**须同时配 `allowBackup=false` + 备份排除**（§2.8 命门）。

## 4. QuickJS 依赖复现性

当前用 Git 依赖接入 `flutter_qjs_next` 并 pin commit。后续若 git fetch/libsecret 仍影响 CI/本机，
可再评估 vendoring 到仓内固定路径或发布到可信 pub 源。

## 5. git / GPG 网络（libsecret 挂起）

- 会话环境里 `git` 的网络命令（fetch/push）与 pub 的 git 依赖 fetch 经 **libsecret** 凭证助手**挂起**（`credential.helper=libsecret`）。
- **GPG 签名**同源问题：pinentry 缓存过期后 `commit -S` 超时；本轮提交先 `--no-gpg-sign`，待人工 rebase 补签。
- **绕行**：远程状态用 `gh api`；已有依赖用 `flutter pub get --offline`；判断分叉先 `gh` 核对而非 `git fetch`。

---

## 待办（人工主导）

- [x] 主线迁 `flutter_qjs_next`：解除 KGP 警告 + ffi 1.x 冲突。
- [x] 将 `flutter_qjs_next` 从本机绝对 path 收敛到 Git 仓库并 pin commit。
- [ ] 单独升级 cryptography 到 2.7+ / 2.9.x。
- [ ] 恢复后加 path_provider，点亮 §2.8 S 档落盘 + `allowBackup=false`。
- [ ] 环境 libsecret / pinentry 修复，恢复正常 git/GPG。
- [ ] 本分支 `--no-gpg-sign` 提交待 rebase 补签。
