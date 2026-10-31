> **已废弃 / Archived（2026-10-31）**：原路径 `docs/architecture.md`。不再作为新开发总则；正文的历史决定、签收和未完成记录原样保留。当前基线见[架构入口](../../../architecture.md)；未迁移 V1 的维护边界见[兼容说明](../../../reference/legacy_compatibility.md)。本文不产生新的开发指令。

# Elecon 架构入口

本文只提供当前架构资料的入口，避免把某个分支的代码快照误当成长期决策。

## 权威顺序

1. [`AGENTS.md`](../AGENTS.pre-2026-10-31.md)：不可违背的安全红线与协作规则。
2. [`ADR-000`](adr/adr_000_abstract.md) 及相关单点 ADR：架构决策与约束。
3. [`ADR 状态索引`](adr/README.md)：分别记录 Decision、Landing、Security signoff、Owner 与 Blocker。
4. 执行状态按路线分开：[`2026-08 整改清单`](planning/2026_08_review_remediation.md) 对应 V1 兼容路径，[受信脚本计划](../../../planning/trusted_scripts.md) 对应 ADR-034 新路径。
5. 代码与自动化测试：当前实现事实；代码存在不代表已经通过安全签收或可生产发布。

发生冲突时，更晚且明确覆盖旧决策的 ADR 优先；实现状态以代码、测试和人工签收证据共同判断，不能用 `Accepted` 推断 `Implemented`。

## 当前分层

- `contract/`：跨端 schema、manifest、adapter SDK 与共享 golden。
- `client/`：Flutter UI 与持有凭证、Broker、签名加载器的可信客户端核心。
- `server/src/public/`：零凭证、无状态的公网分发与公开数据服务。
- `server/src/campus/`：尚未实施的校内授权中继；专项 ADR 接受前保持 501 stub。
- `adapters/`：stdlib、模板、canary 和示例；真实学校 adapter 从 `adapters.pin` 固定的外部仓拉取。
- `tools/`：validator、codegen、签名、发布台账与 release gate。

[ADR-034](../../../adr/adr_034_trusted_school_scripts.md) 新增受信源码路径：用户检查并确认 `elecon-script/1` 包后，普通 async JS 直接读写当前学校身份凭据，编排宿主 HTTP 和可见浏览器 DOM；网络目标由声明的 origin/IP 范围约束，执行仍在背景 isolate。凭据存储、身份、取消和标准输出校验留在宿主，公网不执行新脚本。

V1 official bundle 继续验签、吊销、Broker/Masker 及 declarative/imperative 旧契约；其 ADR-033 本地导入/C3 联动尚未落地。新源码导入已经实现，并不依赖这项旧待办。旧 DSL/Masker 是尚未删除的迁移兼容路径，不再扩充校本协议算子；不是新脚本的必需层。

## 历史资料

2026-07 requestGraph 迁移期的长篇代码档案已归档到
[`archive/architecture_2026-07_request_graph_snapshot.md`](../../../archive/architecture_2026-07_request_graph_snapshot.md)。其中的旧 adapter 布局、`stripEchoes` 和 ADR 状态只用于追溯，不是当前说明。
