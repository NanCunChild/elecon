# docs/archive — 只读档案

这里放**已被取代的规格**与**决策过程记录**。共同点是：读者要执行的东西不在这里。

**归档不是删除**。被否掉的方案、被取代的规格、每次修订的批准记录都必须留存——它们挡的是
「换个人、隔半年，把同一个被否掉的方案重新提一遍」，也是红线合规的凭据。

**本目录的文档一律不是权威**：

| 要找什么 | 去哪 |
|---|---|
| 当前决策 | `docs/adr/` 正文 |
| 落地 / 安全签收状态 | [`docs/adr/README.md`](../adr/README.md)、[`docs/planning/2026_08_review_remediation.md`](../planning/2026_08_review_remediation.md) |
| 契约变更流水 | [`contract/CHANGELOG.md`](../../contract/CHANGELOG.md) |
| 当前架构总览 | `docs/architecture.md` |

与本目录任一文档冲突时，**以上面四处为准**。

## 索引

| 文档 | 内容 | 对应 ADR |
|---|---|---|
| [`bundle_digest_v1_superseded.md`](./bundle_digest_v1_superseded.md) | bundle digest v1 规格、保序重命名攻击复现、v1→v2 四种被否方案的论证 | ADR-002 §2.3 / ADR-018 §2.9.1 |
| [`adr_002_revision_log.md`](./adr_002_revision_log.md) | ADR-002 历次修订的动机、取舍与人工批准记录 | ADR-002 |
| [`architecture_2026-07_request_graph_snapshot.md`](./architecture_2026-07_request_graph_snapshot.md) | 2026-07 requestGraph 迁移期的代码观察快照 | ADR-022 |
