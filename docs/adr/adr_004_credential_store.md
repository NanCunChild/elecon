# ADR-004：Credential Store 与私密数据边界

- **状态**：提议（Proposed）
- **日期**：2026-08-11
- **依赖**：[ADR-002](./adr_002_execution_trust.md)、[ADR-003](./adr_003_core_security_boundary.md)

## 1. 决策

所有受信 adapter 可通过统一 JS API 枚举、读取、写入、更新和删除全部 Credential Store。Store 不对受信 adapter 建立机密性或完整性隔离。

Store 使用结构化复合键，至少包含：

- user profile；
- school / tenant；
- account；
- service / provider；
- credential name / kind。

不得继续只以全局裸字符串 `session`、`token` 寻址。复合键只防止无意重名和串号，不能阻止受信 adapter 故意覆盖其他键。

## 2. API 与一致性

后继 contract 必须定义：

- `list/get/put/delete` 的 typed value；
- 原子写和 compare-and-set/version；
- 多 adapter 并发刷新冲突；
- 过期时间、session 与长期材料；
- logout、账户切换、adapter 删除和应用卸载的数据生命周期；
- 执行取消后不得提交 staged write。

平台后端继续使用 Keychain、Keystore 等安全存储。硬件保护不可用时不得静默谎报保护等级。

## 3. 私密数据路径

真实凭证和学生数据只允许存在于客户端 Credential Store 或用户设备直接发往学校的请求中；系统 VPN 与 official transport/app-tunnel 只承载用户侧链路，不产生项目服务端存储。public 服务、catalog、telemetry、crash report、LLM 审核和 official fixture 均不得接触真实值。

测试只使用合成凭证或脱敏 fixture。V2 不再依赖 opaque handle、自动注入或 mandatory Masker 兑现该边界。

## 4. 必测负例

- 多 profile、学校、账户和 service 不串号。
- 并发 refresh 不以旧值覆盖新值。
- logout/delete/expiry 行为跨平台一致。
- adapter 日志、异常、fixture 和崩溃信息不被宿主自动记录原始值。
