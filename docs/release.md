# CI 自动发版

推送 `vMAJOR.MINOR.PATCH` tag，或手动运行 `Release Flutter artifacts` 并填写已有 tag，即可生成 GitHub Release。构建矩阵包括：

- Android `armeabi-v7a`
- Android `arm64-v8a`
- Windows x64
- Linux x64
- macOS
- iOS（当前为未签名 `.app`，不能直接安装或提交 App Store）

## 必需的 GitHub Actions secrets

Android 正式包必须配置以下 repository secrets：

`ANDROID_KEYSTORE_BASE64`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`。

工作流在 CI 中强制要求 keystore，并通过 `key.properties` 注入 Gradle；keystore 和密码不进入仓库。iOS 要生成可安装 IPA，还需要 Apple 证书、provisioning profile、Bundle ID 和签名密钥。当前工作流先产出未签名包，待 Apple 签名资料准备后再接入签名步骤。

## 发版前提

1. 修改 `client/pubspec.yaml` 的 `version`，或确保 tag 版本与产品版本一致。
2. 为 Android 准备上传签名 keystore。
3. 在 GitHub 仓库启用 Actions，并允许 workflow 创建 release。
4. iOS 包发布前必须补齐 Apple 签名和 App Store Connect 流程。
