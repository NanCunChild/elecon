# ADR 状态索引

本索引把“决策是否接受”和“实现是否落地”分开记录。ADR 正文是决策权威；
[`2026_08_review_remediation.md`](../planning/2026_08_review_remediation.md) 是当前整改与阻塞状态权威。
`Accepted` 只表示可据以实现，**不表示实现、安全签收或生产发布已经完成**。

默认 owner 为 **NanCunChild**。安全签收栏中的“待人工”表示实现或测试触及
`AGENTS.md` 红线，不能由自动测试或 AI 实现替代人工复核。

| ADR | Decision | Landing | Security signoff | Blocker / source |
|---|---|---|---|---|
| [000](./adr_000_abstract.md) | Accepted | 顶层约束生效 | 按子 ADR | 总纲 |
| [001](./adr_001_contract.md) | Accepted | 部分落地 | 契约改动逐项评审 | P1-13/P1-15、P3-04/P3-06 |
| [002](./adr_002_trust_model.md) | Accepted | 部分落地；§2.3 digest v2（2026-09-01 修订）未落地 | 待人工（含 digest v2 修订签收） | P0-01/P0-14 |
| [003](./adr_003_transport.md) | Accepted | 抽象已落地；app-tunnel 未落地 | 待人工 | ADR-032 |
| [004](./adr_004_ui_sdui.md) | Accepted | typed UI 框架已落地 | 按契约改动 | P4-03/P4-05 |
| [005](./adr_005_runtime.md) | Accepted | 已落地 | 已有双端回归 | 共享 golden 只覆盖已使用语义 |
| [006](./adr_006_school_auth.md) | Deferred | 不实施 | 不适用 | 由 ADR-012 通用路径覆盖 |
| [007](./adr_007_public_deploy.md) | Deferred | 不实施 | 不适用 | P3-15 有真实部署需求时重启评审 |
| [008](./adr_008_client_runtime.md) | Accepted | 已落地 | 按 runtime 改动 | P2-09 |
| [009](./adr_009_fetch_credential.md) | Accepted | 部分落地 | 待人工 | P0-10 |
| [010](./adr_010_ios_appstore.md) | Accepted | 分发约束生效；正式上架未闭环 | 待人工/外部 | P3-13/P3-14 |
| [011](./adr_011_html_parser.md) | Accepted | 分批落地 | 按 runtime 改动 | 正文 §4 |
| [012](./adr_012_credential_store.md) | Accepted | 部分落地 | 待人工/真机 | P0-06/P0-07、P1-01/P1-03 |
| [013](./adr_013_manifest_credentials.md) | Accepted | 基线契约与 loader 已落地 | 已有人工评审；增量另审 | 后续最小权限见 P4-02 |
| [014](./adr_014_client_host_fn.md) | Accepted | 基线 host-fn 已落地 | 已有人工评审；增量另审 | P0-10 |
| [015](./adr_015_manifest_login.md) | Accepted | 已落地 | 已有人工评审；增量另审 | 平台能力见 ADR-016 |
| [016](./adr_016_complex_login.md) | Accepted | 部分平台落地 | 待真机/人工 | P2-12/P2-13 |
| [017](./adr_017_sso_master_credential.md) | Accepted | 部分落地 | 待人工 | Xidian mint 闭环计划 |
| [018](./adr_018_adapter_distribution.md) | Accepted | 部分落地；§2.9.1 digest v2 与上线形态（2026-09-01 新增）未落地 | 待人工（含 §2.9.1 签收） | P0-01/P0-15、P3-07/P3-08 |
| [019](./adr_019_classroom_available.md) | Accepted | 契约与 UI 基线已落地 | 契约已评审 | adapter 签发/真机仍开放 |
| [020](./adr_020_url_query_credential.md) | Accepted | 已落地 | 已人工复核 | 真机验收仍开放 |
| 021 | Reserved | 未起草 | 不适用 | P3-05 先决定 Money 领域语义 |
| [022](./adr_022_request_graph.md) | Accepted | 基线已落地 | 已人工复核 | fixture 全编排见 P1-17 |
| [023](./adr_023_declarative_dataflow.md) | Accepted | MVP 已落地 | 2026-07-24 owner 签收 | [落地清单](../reference/declarative_dataflow_migration.md) |
| [024](./adr_024_build_profile_trust.md) | Accepted | 零入口 slice 0–4 已落地（Android 有产物证据）；gate 待随 ADR-033 落地重做 | 待人工签收（新 gate 落地后一并签） | P0-14、[落地清单](../reference/adr_024_landing.md) |
| [025](./adr_025_item_link.md) | Accepted | 契约/UI 基线已落地 | 外跳路径增量另审 | ADR 正文 §2.7 |
| [026](./adr_026_response_masker.md) | Accepted | 部分落地 | 待人工 | P0-09/P0-10、P1-08/P1-09 |
| [027](./adr_027_url_session_param_stripping.md) | Accepted | 实现已提交 | 待人工 | 纳入 P0-10 firewall 总签收 |
| [028](./adr_028_declarative_crypto_ops.md) | Accepted | 双端实现与 golden 已完成 | 待 owner | [安全清单](../reference/declarative_dataflow_security_checklist.md) |
| [029](./adr_029_named_and_body_credentials.md) | Accepted | named header 已落地；body 未落地 | 待人工 | P1-11 |
| [030](./adr_030_actuator_capabilities.md) | Accepted | 未落地 | 待人工 | P1-12 |
| [031](./adr_031_dataflow_seed.md) | Accepted | 未落地 | 待人工 | P1-10 |
| [032](./adr_032_app_tunnel_embedding.md) | Proposed | 禁止实现 | 待人工评审 | 接受前不得合并 transport 实现 |
| [033](./adr_033_production_sideload.md) | Accepted | **未落地**（现仍为 DEPLOY 零本地导入 + C3 在位） | 落地须人工主导 + 安全清单 + ≥1 人工审 | §5 连带清单须同批落地；§6 开放问题按实现分项阻塞 |

更新规则：接受或废弃 ADR 时更新 `Decision`；实现 PR 只更新 `Landing`；安全签收必须附人工复核引用，不能以 smoke 通过代替。
