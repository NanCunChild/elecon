# Elecon V2 架构入口

本文只提供 V2 当前架构资料的入口。代码仍处于 V1→V2 迁移期，代码存在不表示它是
现行契约，也不表示已经通过安全签收。

## 权威顺序

1. [`AGENTS.md`](../AGENTS.md)：不可违背的安全红线与协作规则。
2. [`ADR-000`](./adr/adr_000_abstract.md) 及相关单点 ADR：架构决策与约束。
3. [`ADR 状态索引`](./adr/README.md)：记录 V2 Decision、Landing 与 review 状态。
4. [`V2 Migration`](./planning/v2_migration.md)：迁移顺序、替代门和旧实现删除条件。
5. 代码与自动化测试：当前实现事实；代码存在不代表已经通过安全签收或可生产发布。

发生冲突时，更晚且明确覆盖旧决策的 ADR 优先；实现状态以代码、测试和人工签收证据共同判断，不能用 `Accepted` 推断 `Implemented`。

## 当前分层

- `contract/`：跨端 schema、manifest、adapter SDK 与共享 golden。
- `client/`：Flutter UI、执行准入、QuickJS、Credential Store、宿主网络和平台能力。
- `server/src/public/`：零凭证、无状态的公网分发与公开数据服务。
- `server/src/campus/`：尚未实施的校内授权中继；专项 ADR 接受前保持 501 stub。
- `adapters/`：stdlib、模板、canary 和示例；真实学校 adapter 从 `adapters.pin` 固定的外部仓拉取。
- `tools/`：validator、replay、LLM finding 接口、codegen、签名、发布台账与 release gate。

V2 adapter 是项目或用户选择信任的本地程序，使用普通异步 JavaScript 自行读取凭证、
编排学校流程并输出标准 schema。official 自动受信；支持的平台允许用户按 exact bundle
digest 整体信任 local unsigned；iOS 仅运行 official。所有 adapter 仍受 QuickJS、宿主唯一
网络出口、资源预算和标准输出校验约束。

## 历史资料

V1 ADR、notes、planning、probes 和 reference 已分别归档到各目录的 `archived/v1/`。
2026-07 requestGraph 长篇代码快照另见
[`archive/architecture_2026-07_request_graph_snapshot.md`](./archive/architecture_2026-07_request_graph_snapshot.md)。
