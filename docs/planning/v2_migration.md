# V2 Migration

- **状态**：进行中
- **决策基准**：[`ADR-000`](../adr/adr_000_abstract.md) 及 V2 后继 ADR

## 阶段

| 阶段 | 目标 | 删除旧门的条件 |
|---|---|---|
| M0 | 冻结 V1 文档，建立 V2 ADR 与 CI 文档结构门 | 不删除 runtime gate |
| M1 | Manifest V2、统一 SDK、bundle digest trust | V2 contract gate 阻塞通过 |
| M2 | QuickJS 执行准入、宿主出网和 Credential Store API | V2 安全 golden 双端通过 |
| M3 | 转换全部 official adapter 与 fixture | pinned adapter 无 V1 requestGraph |
| M4 | official 审核、LLM scan、签名/catalog/revocation | exact digest 人工签署链通过 |
| M5 | iOS official-only、WebView、transport 平台门 | 真机与 release artifact gate 通过 |
| M6 | 删除 declarative/dataflow/Masker/旧 trust profile | 所有替代门已成为 required checks |

## 原则

- 先增加 V2 阻塞门，再删除对应 V1 断言。
- 迁移期间现有 V1 runtime 测试作为 legacy baseline 保留，不代表 V1 仍是目标架构。
- 不建立空壳、`continue-on-error` 或只输出 TODO 的安全 job。
- contract、Credential Store、网络出口、签名、WebView 和 transport 的实现分别受对应 ADR 阻塞。
