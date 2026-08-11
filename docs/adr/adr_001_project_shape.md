# ADR-001：V2 项目形态与责任拓扑

- **状态**：提议（Proposed）
- **日期**：2026-08-11
- **依赖**：[ADR-000](./adr_000_abstract.md)

## 1. 决策

V2 由五个责任单元组成：

1. **Flutter 客户端可信宿主**：执行准入、QuickJS、Credential Store、宿主网络、UI 和平台能力。
2. **QuickJS adapter 层**：受信 JavaScript 自行完成认证、请求、计算、解析和标准 schema 输出。
3. **公网哑服务 `server/src/public`**：只分发公开工件和缓存公开数据，零凭证、无私密持久化。
4. **校内授权中继 `server/src/campus`**：仅在学校授权环境处理私密请求，不与公网哑服务混部信任状态。
5. **审核与发布治理面 `tools/`**：validator、replay、LLM threat scan、人工审核、离线签名、catalog 和吊销。

`contract/` 是客户端、runtime、tools、adapter 与 UI 的跨端事实来源。adapter 源码位于独立公开仓，本仓通过钉死的 exact ref 获取；缓存目录、生成目录和 `dist-*` 不是信任源。

同一 adapter 可在客户端、审核 replay 和未来的校内中继运行。公网环境不得运行需要真实用户凭证或私密响应的任务。

UI 只消费标准 schema。adapter 更新可以实现既有 capability，不能凭空增加客户端 UI、原生模块、transport 或新的宿主能力。

## 2. 边界

- 客户端是终端用户侧最终执行信任根。
- public 与 campus 必须保持代码入口、部署身份、密钥和数据路径隔离。
- client/server QuickJS 只对共享 golden 覆盖的已使用语义承诺一致。
- V1 代码在迁移期存在不代表其仍是 V2 契约。

## 3. 风险与验证

- 防止 public runtime 误接 Credential Store 或 campus 私密路径。
- 防止 `adapters.pin`、源码、构建 bundle 和签名身份错配。
- 对跨端 QuickJS、schema、host API 和 fixture 保持共享测试。
- campus relay 必须另有 ADR 后才能实现或部署。
