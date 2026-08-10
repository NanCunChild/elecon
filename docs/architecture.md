# Elecon 架构入口

本文只提供当前架构资料的入口，避免把某个分支的代码快照误当成长期决策。

## 权威顺序

1. [`AGENTS.md`](../AGENTS.md)：不可违背的安全红线与协作规则。
2. [`ADR-000`](./adr/adr_000_abstract.md) 及相关单点 ADR：架构决策与约束。
3. [`ADR 状态索引`](./adr/README.md)：分别记录 Decision、Landing、Security signoff、Owner 与 Blocker。
4. [`2026-08 整改清单`](./planning/2026_08_review_remediation.md)：当前实现缺口、前置关系与完成条件。
5. 代码与自动化测试：当前实现事实；代码存在不代表已经通过安全签收或可生产发布。

发生冲突时，更晚且明确覆盖旧决策的 ADR 优先；实现状态以代码、测试和人工签收证据共同判断，不能用 `Accepted` 推断 `Implemented`。

## 当前分层

- `contract/`：跨端 schema、manifest、adapter SDK 与共享 golden。
- `client/`：Flutter UI 与持有凭证、Broker、签名加载器的可信客户端核心。
- `server/src/public/`：零凭证、无状态的公网分发与公开数据服务。
- `server/src/campus/`：尚未实施的校内授权中继；专项 ADR 接受前保持 501 stub。
- `adapters/`：stdlib、模板、canary 和示例；真实学校 adapter 从 `adapters.pin` 固定的外部仓拉取。
- `tools/`：validator、codegen、签名、发布台账与 release gate。

adapter 的**能力/信任面越薄越好**，但作为吸收学校接口差异的 shim，其**归一化和校本派生功能应尽量完整**。DEPLOY 只运行通过 official 验签与吊销门禁的 adapter；本地导入只可作为 official bundle 的另一字节来源。DEV-Sideload 是全能力开发环境，可调试未签名 declarative / imperative adapter。双渠道与 C3 退役见 ADR-033（已接受，尚未落地）。

## 历史资料

2026-07 requestGraph 迁移期的长篇代码档案已归档到
[`archive/architecture_2026-07_request_graph_snapshot.md`](./archive/architecture_2026-07_request_graph_snapshot.md)。其中的旧 adapter 布局、`stripEchoes` 和 ADR 状态只用于追溯，不是当前说明。
