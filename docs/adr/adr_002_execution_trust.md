# ADR-002：执行信任、official 与本地 digest trust

- **状态**：提议（Proposed）
- **日期**：2026-08-11
- **依赖**：[ADR-001](./adr_001_project_shape.md)

## 1. 决策

信任只由宿主裁定。manifest 的字段、adapter ID、文件名、目录来源或自报 tier 均不能产生信任。

MVP 只有两条生产执行路径：

1. **official**：官方验签、bundle identity、兼容门、catalog 和 revocation 全部通过后自动受信。
2. **local unsigned**：受支持平台由用户明确保存 exact bundle digest trust 后受信。

local trust 是对整个 bundle 和全部 adapter 能力的整体信任。digest 变化即新代码，不继承旧信任。用户可撤销 trust、禁用或删除 adapter；三者的持久化语义必须分别实现。

MVP 不实现用户自签、第三方签名者信任、按 adapter ID 自动继承或同来源自动更新。未来的签名者信任必须另立 ADR，且有效签名不得自动等价为 official。

受信 adapter 可读写全部 Credential Store 和私密响应。不存在“local unsigned 低权限档”。DEV profile 只提供诊断和临时开发便利，不构成第三条生产信任路径。

## 2. 信任记录

local trust 至少绑定：

- canonical bundle digest 算法与版本；
- exact digest；
- adapter identity，仅用于展示和防混淆，不替代 digest；
- 创建时间、来源提示和撤销状态。

信任记录不得随普通应用备份或跨设备同步而静默扩散。执行前必须重新绑定实际加载字节，禁止“先验 digest、后换文件”的 TOCTOU。

## 3. 平台门

- Android 和允许动态本地代码的平台可启用 local digest trust。
- iOS 仅铸造 official 执行 grant，详见 ADR-009。
- 无效签名不得静默降级成 unsigned 并继承既有 trust。

## 4. 必测负例

- 未信任 digest 不执行；同 ID 不继承；字节变化不继承。
- trust 撤销后新调用和后台任务均不能启动。
- official identity、signature、catalog 与 bundle bytes 任一不闭合即拒绝。
- DEV grant、测试 signer 和导入绕过不得进入 release 产物。
