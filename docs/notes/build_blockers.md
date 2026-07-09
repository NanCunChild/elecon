# 构建/依赖阻塞情况说明（build blockers）

> 状态记录，非 ADR。记录当前卡住工具链升级与依赖更新的几个相互纠缠的问题，供后续处理时参考。
> 最后更新：2026-07-09。

## TL;DR

| 阻塞 | 现状 | 根因 | 影响 |
|---|---|---|---|
| **AGP 版本** | 已修到 8.11.1 | 曾降到 8.9.2（< Flutter 下限）| 已解决（清除弃用警告）|
| **flutter_qjs 停更 fork** | 钉在补丁 fork | 上游 ekibun 停更 | 拖累 ffi/Kotlin/Java（见下）|
| **cryptography 版本** | 钉 2.6.x | flutter_qjs 锁 ffi 1.x | 用不了 2.7+ |
| **path_provider 加不进** | 未加入 | pub 拉 git 依赖经 libsecret 挂起 | §2.8 落盘未点亮（内存档）|
| **KGP 弃用警告** | 未解 | flutter_qjs 自 apply Kotlin Gradle Plugin | 未来 Flutter 会 fail |
| **git/GPG 网络** | 绕行中 | libsecret 凭证助手挂起 | pub git fetch / commit 签名超时 |

---

## 1. AGP（已解决）

- 提交 `3731204` 用 AGP **9.0.1**；工作树一度降到 **8.9.2**（+ 给 flutter_qjs 加 Java 11 兼容）。
- 8.9.2 **低于** Flutter 3.44 的 AGP 下限 **8.11.1** → 每次构建「will soon be dropped」弃用警告，且未来 Flutter 升级会 fail。
- **处理（提交 `42b79a4`）**：升到 **8.11.1**——实测构建通过、警告消除，仍留 8.x 避开 AGP 9.0.x 对 flutter_qjs 的 Kotlin/Java 兼容坑。
- **暂不上 AGP 9.0.x**：会重新触发导致当初降级的兼容问题；待 flutter_qjs 适配后再评估。

## 2. flutter_qjs 停更 fork —— 一切纠缠的根

`flutter_qjs`（ekibun）上游已停更，项目用补丁 fork（`NanCunChild/flutter_qjs@dbf5c17`，Dart 3 兼容，见 ADR-008 §3）。它是 QuickJS 承重依赖（ADR-014），但拖累多条线：

- **ffi 锁 1.x** → `cryptography` 只能用 **2.6.x**（2.7+ 依赖 ffi ^2.1，冲突）。ADR-012 §2.8 的 AES-256-GCM 因此钉 2.6.x。
- **Kotlin Gradle Plugin（KGP）弃用警告**：flutter_qjs 自 apply KGP，Flutter 警告「未来版本会 fail if your app uses plugins that apply KGP」。**这不是 AGP/Gradle 版本能解的**，是插件写法问题。
- **Java 兼容**：需给 flutter_qjs 强钉 Java 11（root `build.gradle.kts` 的 `compileOptions` + `KotlinCompile.jvmTarget`），否则较新 AGP/JDK 下编译失败。

**根治方向**（任一，人工主导）：
1. 把 fork 迁到 **built-in Kotlin**（去掉自 apply KGP）+ 升 ffi → 同时解掉 KGP 警告与 cryptography 2.6 钉。
2. 或**换 QuickJS 绑定 / vendoring**（移除 git 依赖，见 §4）。

## 3. path_provider 加不进（§2.8 落盘未点亮）

- ADR-012 §2.8 的 **S 软件档**需要 app 私有目录落盘，本应加 `path_provider`。
- `flutter pub get` 拉取 flutter_qjs 的 **git 依赖**时经 libsecret 挂起（§5），在线解析卡死；离线缓存又没有 path_provider → **加不进**。
- **规避（提交 `38b2175`）**：BlobStore 做成**可注入接缝**，`main.dart` 的 provider 暂返回 null → 退化为 **M 内存档**（不落盘）。§2.8 其余流程（硬件检测→警告框→分级→flush）已全部接线并测试。
- **恢复步骤**：网络/依赖恢复后 `flutter pub add path_provider`，在 `main.dart` 把 provider 换成
  `FileBlobStore(Directory('${(await getApplicationSupportDirectory()).path}/credentials'))` 即点亮持久化。**须同时配 `allowBackup=false` + 备份排除**（§2.8 命门）。

## 4. 建议：给 flutter_qjs 去 git 依赖（vendoring）

pub 对 **git 依赖**每次 `get` 都尝试 `git fetch`（§5 挂起点）。把 fork 的产物 **vendoring 进仓**（或发到私有 pub / 用 path 依赖）可**同时**解决：
- pub get 不再 git fetch → 不受 libsecret 挂起影响（path_provider 等新依赖可正常加）；
- 依赖可复现、不依赖 GitHub 可达性。
成本：需维护 vendoring 更新流程。属人工主导决策（触 ADR-008/014 承重依赖）。

## 5. git / GPG 网络（libsecret 挂起）

- 会话环境里 `git` 的网络命令（fetch/push）与 pub 的 git 依赖 fetch 经 **libsecret** 凭证助手**挂起**（`credential.helper=libsecret`）。
- **GPG 签名**同源问题：pinentry 缓存过期后 `commit -S` 超时；本轮提交先 `--no-gpg-sign`，待人工 rebase 补签。
- **绕行**：远程状态用 `gh api`；已有依赖用 `flutter pub get --offline`；判断分叉先 `gh` 核对而非 `git fetch`。

---

## 待办（人工主导）

- [ ] flutter_qjs fork：迁 built-in Kotlin + 升 ffi（解 KGP 警告 + cryptography 2.6 钉）。
- [ ] flutter_qjs 去 git 依赖（vendoring / path），解 pub git fetch 挂起。
- [ ] 恢复后加 path_provider，点亮 §2.8 S 档落盘 + `allowBackup=false`。
- [ ] 环境 libsecret / pinentry 修复，恢复正常 git/GPG。
- [ ] 本分支 `--no-gpg-sign` 提交待 rebase 补签。
