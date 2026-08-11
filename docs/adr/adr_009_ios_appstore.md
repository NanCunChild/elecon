# ADR-009：iOS official-only 与 App Store 上架

- **状态**：提议（Proposed）
- **日期**：2026-08-11
- **依赖**：[ADR-002](./adr_002_execution_trust.md)、[ADR-003](./adr_003_core_security_boundary.md)、[ADR-005](./adr_005_adapter_v2.md)、[ADR-006](./adr_006_official_governance.md)、[ADR-007](./adr_007_transport.md)、[ADR-008](./adr_008_webview_login.md)

## 1. 平台裁定

iOS 使用与其他平台相同的普通异步 JavaScript adapter，不恢复 declarative/dataflow 作为特例，但只允许运行 official adapter。

iOS MVP 不提供 local unsigned digest trust、用户自签、签名者信任或本地代码导入执行。共享导入代码可以存在，但 UI 入口、loader、runtime 和 release artifact 必须共同执行 official-only；仅隐藏入口不构成边界。

下载 adapter 只能实现 App 已内置的固定 capability 和标准 schema，不能增加 UI、native module、transport、支付或任意宿主能力。App bundle 预置可运行的 official baseline，保证提交 build 自包含并可供审核演示。

## 2. 上架材料

发布前必须准备并人工复核：

- DPLA 3.3.2 与 App Review 动态代码说明；
- 固定 capability/host API 清单及非代码市场论证；
- reviewer notes、演示账号和离线 baseline 路径；
- privacy policy、Privacy Manifest 和第三方 SDK 声明；
- archive/export、provisioning、entitlements 和 codesign 验证；
- official catalog、adapter 更新和 transport 的审核说明。

Apple 政策变化、新 host API、新 capability、local import、app-tunnel 或 WebView 能力变化均触发重新评估。

## 3. Release gates

- release 构建中不存在 local trust factory、测试 signer、DEV transport 或导入 bypass。
- loader/runtime 对 unsigned、未知 signer、无效 signature、非 catalog bundle 均有负例。
- QuickJS 构建不得依赖 JIT/W^X 不兼容能力。
- 审核 build 与实际分发 build 使用相同 trust、adapter baseline 和 transport 配置。

## 4. 残余风险

Apple 仍可能把下载并执行 official adapter 认定为改变功能或代码分发。技术门不能替代商店政策判断；若审核结论不接受该形态，须另立 ADR 决定功能收缩或分发渠道，不得静默放宽 official-only。
