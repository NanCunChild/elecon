# 参考文档

- [Track B 实施草案 —— 命令式 requestGraph 运行时](./track_b_imperative_runtime_plan.md)（落地 ADR-009 §4，🔒 人工主导；旧称 fetch 模式）
- [B4 实现计划 —— per-execution cookie jar（两分区）](./b4_cookie_jar_plan.md)（ADR-009 §2.4，🔒 人工主导）
- [B5 实现计划 —— 耐久 cookie 收割桥接](./b5_harvest_bridge_plan.md)（ADR-009 §2.4 / ADR-012，🔒 人工主导，含 🔴 开放点）
- [B6 实现计划 —— ctx.fetch 代理 + 异步运行时 + 限额](./b6_imperative_runtime_plan.md)（ADR-009 §2.1/§2.7，🔒 人工主导，含开放点）
- [WebView 登录收割 + XIDIAN 取数可行性](./webview_login_fetch_feasibility.md)（ADR-012/015/016，🔒 人工主导）
- [XIDIAN 全闭环 + SSO mint 签票](./xidian_mint_closed_loop_plan.md)（ADR-017，🔒 接线/执行人工主导）
- [ADR-023 声明式跨请求数据流落地清单](./declarative_dataflow_migration.md)（准备阶段；§5 开放问题勾决后落地，🔒 人工主导）
- [跨端日志策略](./cross_end_logging.md)（DevLog 唯一 sink、默认脱敏、campus 不落凭证）
- [离线 YubiKey 签名密钥 Ceremony](./signing_ceremony.md)（密钥生成 / PIN / 公钥预埋；**不得由 AI 执行**）
- [Adapter 发布 runbook](./adapter_release.md)（每次发版：unsigned → digest 比对 → `release:package` → 端点 D）
- [adapter-sdk 类型声明](../../contract/adapter-sdk/types.d.ts)
- [manifest 规范](../../contract/manifest.schema.json)
- [标准 schema 索引](../../contract/schema/)
- [capability 注册表](../../contract/capability/registry.json)
