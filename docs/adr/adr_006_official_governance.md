# ADR-006：official 审核、LLM 扫描与发布治理

- **状态**：提议（Proposed）
- **日期**：2026-08-11
- **依赖**：[ADR-002](./adr_002_execution_trust.md)、[ADR-003](./adr_003_core_security_boundary.md)、[ADR-005](./adr_005_adapter_v2.md)

## 1. official 含义

official 是项目对 exact `.eleb` canonical execution content digest 及其完整 variant 集合的严格审核和背书。它不是作者、仓库分支或 adapter ID 的永久身份，也不是“签名有效”的同义词；gzip/zip 等外层容器的偶然序列化字节不是 execution identity。

official 自动获得完整 adapter runtime 能力、自身 Credential namespace 和 manifest 已声明的跨 namespace 模式，因此审核错误仍具有最高影响，必须使用比 local signer trust 更严格的供应链治理。official 静默加载不等于绕过 namespace enforcement。

## 2. 发布流水线

official 流水线至少包含：

1. manifest/bundle deterministic validator；
2. dependency、license、secret 和 fixture PII scan；
3. QuickJS replay、schema 和资源预算测试；
4. manifest 网络声明与观测行为对比；
5. LLM threat scan；
6. 人工代码、依赖、fixture、行为和风险复核；
7. 人工批准 exact digest；
8. 离线硬件签名；
9. 自包含 official `.eleb`、独立 revocation、非权威 discovery index 和 release ledger 发布。

构建、依赖或字节发生任何变化均须重新审核。CI 不持 official 私钥，不能自行将 finding 标记为已解决并签名。

## 3. LLM 边界

LLM 用于解释控制流、发现凭证/日志/外传路径、比较更新 diff 和生成 reviewer checklist。adapter 源码、文档、fixture 和响应均视为提示注入输入。

必须保存模型、版本、提示模板、输入 digest、输出 finding 和人工处置。LLM 无真实凭证、生产数据或签名密钥，只能产生 finding，不能自动放行、压制 deterministic gate 或成为最终签署者。

## 4. 签名、发现与吊销

- signature、`.eleb` identity、canonical digest 和 compatibility 必须在自包含 bundle 内闭合，不依赖 runtime catalog。
- 私钥片上生成并离线使用，定义 active/backup key、轮换、泄露和丢失流程。
- 独立 revocation sequence 防回滚，支持按 signer/adapter/version/digest 吊销。
- official discovery index 只用于列表、搜索、下载和更新提示，不参与执行信任；索引签名可保护分发质量，但不能铸造 official grant。
- offline last-good revocation 和新安装策略必须明确，不能在网络失败时无条件 fail-open。

official bytecode-only `.eleb` 可以不公开源码，但审核方必须取得对应源码，并分别审查或行为验证所有 QuickJS ABI variants。整个 `.eleb` 的官方签名证明项目批准该 variant 集合，不证明 variants 可复现地来自同一源码或逻辑一致。

## 5. 对抗重点

人工与 LLM 必须检查时间触发、账户触发、地区触发、异常路径、编码外传、允许域内写接口、依赖投毒和“所审非所签”。最终责任由人工 reviewer 与 signer 承担。
