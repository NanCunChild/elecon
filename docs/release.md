# App 工件 CI 自动发版

推送 `vMAJOR.MINOR.PATCH` tag，或手动运行 `Release Flutter artifacts` 并填写已有 tag，即可生成 GitHub Release。

发版先通过 immutable tag/SHA preflight，再复用完整 `.github/workflows/ci.yml`，经受保护 Environment 人工批准后构建并发布。任一 required job 失败即阻断。当前 CI 同时包含 V2 文档结构门和 V1 runtime legacy baseline；通过不等于 V2 runtime 已完成迁移。

本页只描述 App 平台工件。official adapter 的审核、离线签名、catalog 和 revocation 由 ADR-006 及其未来 V2 runbook 负责；不得继续按 V1 archived release runbook 发布 V2 adapter。

## 构建矩阵与签名状态

| 平台 | 产物 | 签名 |
|---|---|---|
| Android `armeabi-v7a` / `arm64-v8a` | APK（split-per-abi） | **已就绪**：配 keystore secrets 后正式签名 |
| Linux x64 | `.tar.gz` bundle | 无 OS 级代码签名门槛，可直接运行 |
| macOS | `.app`（zip） | **条件签名**：配了证书 secrets 就 codesign，否则未签名 |
| Windows x64 | `.zip` | 未签名（OV 证书暂缺，SmartScreen 会告警） |
| iOS | 未签名 `.app`（zip） | 未签名，**不能直接安装或提交 App Store** |

> **OHOS/HAP 不在发版矩阵内。** 主线依赖已迁 `flutter_qjs_next`，OHOS 旁路仍用旧 `flutter_qjs` fork（`pubspec.ohos.yaml`），需由新的 V2 平台 probe 验证后再纳入。V1 状态快照见 `docs/notes/archived/v1/build_blockers.md` §2。

> 仓库只提交了 `android/ios/linux` 平台目录；`macos/windows` runner 未入库，流水线在构建前按需 `flutter create` 脚手架。

## GitHub Actions secrets

**Android（正式包必需）：**
`ANDROID_KEYSTORE_BASE64`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`。
工作流在 CI 中强制要求 keystore，并通过 `key.properties` 注入 Gradle；keystore 和密码不进入仓库。

**macOS（可选，配了才签名）：**
`MACOS_CERTIFICATE_BASE64`（Developer ID Application 证书导出的 `.p12` 的 base64）、`MACOS_CERTIFICATE_PASSWORD`、`MACOS_SIGN_IDENTITY`（如 `Developer ID Application: Name (TEAMID)`）。
未配置时产出未签名 `.app`（用户侧被 Gatekeeper 拦，需右键打开）。**公证（notarization）尚未接入**，待后续补齐。

**Windows / iOS：** 暂无签名渠道。Windows OV 证书、Apple 证书 / provisioning profile / Bundle ID / App Store Connect 流程均待补齐。当前 unsigned iOS `.app` 只是 CI 工件，不是 App Store 产物；V2 上架受 ADR-009 阻塞。

## 发版前提

1. 版本号以 **git tag 为准**：CI 用 `--build-name`（tag 去 `v` 前缀）+ `--build-number`（run number）覆盖。`client/pubspec.yaml` 的 `version` 仅作本地构建基线，二者不必逐位同步。
2. 为 Android 准备上传签名 keystore 并配好上述 secrets。
3. 在 GitHub 仓库启用 Actions，并允许 workflow 创建 release（`permissions: contents: write`）。
4. 需要签名的 macOS 包：配齐 macOS 证书 secrets。
5. iOS / Windows 正式分发前，分别补齐 Apple 与 Windows 代码签名资料。
