# ADR-007：Transport 与 app-tunnel 边界

- **状态**：提议（Proposed）
- **日期**：2026-08-11
- **依赖**：[ADR-001](./adr_001_project_shape.md)、[ADR-003](./adr_003_core_security_boundary.md)、[ADR-004](./adr_004_credential_store.md)

## 1. 决策

transport 是官方应用组成部分，不属于 adapter bundle、SDK、local digest trust 或未来签名者信任。release 只加载随官方应用构建并通过平台产物门的 transport。

adapter 无论 official 或 local，都不能提供 native transport、raw socket、VPN、TLS MITM、任意代理模块或底层 stream。adapter 只发起宿主已裁定的请求，transport 只执行单跳搬运。

transport 必须：

- 不自动重定向；
- 不改变目标 origin；
- 不关闭 TLS 验证、不安装根证书、不终止内层 TLS；
- 不持久化 Credential Store 或请求内容；
- 正确传播取消、deadline 和资源预算；
- 对非幂等请求不自动重试。

dev transport 仅存在于 debug build，release 必须在构建产物层证明其不存在，不能只隐藏入口。

## 2. app-tunnel

app-tunnel 必须另行定义：

- 生命周期与单 active transport；
- 会话材料由宿主管理、最短生命周期和 zeroize；
- TLS、证书/SPKI 校验；
- 失败时 fail-closed 或回退到明确允许的 direct，不得回退公网代取；
- Android/iOS entitlement、商店政策和真机测试；
- GPL/AGPL、私有协议授权和依赖供应链。

V1 Hermes/aTrust probe 只作历史输入，复用前必须按当前依赖和平台版本重新验证。

## 3. 必测负例

- release 无动态 native transport 注册、反射加载和 dev bypass。
- transport 不能跟随 allow 外重定向或修改 destination。
- TLS verify=false、根证书注入、明文材料落盘和取消后继续发送均被拒绝。
