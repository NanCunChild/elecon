# V2 ADR 索引

本目录只记录 V2 当前有效的架构决策。V1 决策已冻结在
[`archived/v1/`](./archived/v1/README.md)，仅用于解释历史代码和迁移来源，不再作为
新实现的规范依据。

ADR 编号从 `000` 重新开始。`Accepted` 表示决策可据以实现，不表示实现、测试、安全
复核或生产发布已经完成。

| ADR | Decision | Landing | Review |
|---|---|---|---|
| [000](./adr_000_abstract.md) | Accepted | V2 总则生效；实现迁移未开始 | 后继契约、凭证、网络、签名与平台 ADR 须分别评审 |
| [001](./adr_001_project_shape.md) | Accepted | campus 已删除、public 构建已收窄；服务端 runtime/双跑待清理 | 客户端单一执行面、fixture 与 golden 审计已评审 |
| [002](./adr_002_execution_trust.md) | Accepted | 旧 official/catalog loader 仍在；三路径未实现，受 ADR-005 阻塞 | official/local signer/过渡 unsigned、无 catalog 准入与退役门已评审；安全实现仍须人工复核 |
| [003](./adr_003_core_security_boundary.md) | Accepted | 未实现；受 ADR-004/005 契约前置阻塞 | QuickJS、网络、预算、事务与输出边界已评审；安全实现仍须人工复核 |
| [004](./adr_004_credential_store.md) | Accepted | 未实现；contract/API 受 ADR-005 阻塞 | profile 边界、namespace/key、value、生命周期、加密与迁移已评审；安全实现仍须人工复核 |
| [005](./adr_005_adapter_v2.md) | Accepted | `.eleb` 格式、检测器、digest/signature 基座已落地；V2 loader/trust 接线未完成 | Manifest V2、deterministic ZIP `.eleb`、source/bytecode-only、签名与 QuickJS ABI 已评审；安全实现仍须人工复核 |
| [006](./adr_006_official_governance.md) | Proposed | 未实现 | LLM+人工审核、签名与吊销 |
| [007](./adr_007_transport.md) | Proposed | 未实现 | transport/app-tunnel |
| [008](./adr_008_webview_login.md) | Proposed | 未实现 | 宿主 WebView 与收割 |
| [009](./adr_009_ios_appstore.md) | Proposed | 未实现 | iOS official-only 与上架 |
| [010](./adr_010_signer_identity.md) | Accepted | 未实现；contract 受 ADR-005 阻塞 | adapterId、第三方 signer trust、更新连续性与 namespace 清空已评审 |
| [011](./adr_011_capability_response_cache.md) | Accepted | 未实现；依赖 ADR-003/004/005/010 基础设施 | capability 完整响应缓存的身份、访问控制、加密、失效与测试边界 |

## 更新规则

- V2 架构、契约、凭证、执行信任、网络出口、签名或 transport 改动必须先有 ADR。
- 新 ADR 只依赖本目录中的 V2 ADR；引用 V1 归档只能作为历史背景或迁移证据。
- 接受或废弃 ADR 时更新 `Decision`；实现 PR 只更新 `Landing`。
- 安全敏感实现和测试仍须人工实质性复核，自动检查和 LLM 结论不能代替签收。
