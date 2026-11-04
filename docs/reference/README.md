# 专项参考

日常入口只有[现行架构](../architecture.md)、[作者手册](../wiki/README.md)和[统一实施计划](../planning/implementation.md)。本目录提供按需查询的协议、平台与兼容资料，不另维护项目状态或完整 SDK 教程。

| 需要核对的细节 | 参考 |
|---|---|
| 安装包与 API 精确字段 | [SDK 类型](../../contract/script-sdk/types.d.ts)、[包 schema](../../contract/script-package.schema.json)、[领域 schema](../../contract/schema/)与[registry](../../contract/capability/registry.json) |
| 首页布局与来源覆盖 | [使用说明](card_layout_and_overrides.md) |
| 浏览器容器、密码与隧道账号 | [浏览器](script_browser_surfaces.md)、[保存密码](script_account_passwords.md)、[凭据复用](script_credential_reuse.md)、[隧道账号](script_tunnel_accounts.md) |
| 语言代码与原生平台 AI | [语言代码](script_language_codes.md)、[Android AppFunctions](android_app_functions.md) |
| 学校协议观察 | [HAR 录制](browser_har_capture.md)、[浏览器追踪](browser_auth_trace.md)、[西电认证对照](xidian_pda_auth_comparison.md)、[能力对照](xidian_script_update.md) |
| 依赖、发布与日志 | [依赖许可](trusted_scripts_dependencies.md)、[发布](release_workflow.md)、[日志](cross_end_logging.md) |
| 旧运行时维护 | [兼容边界](legacy_compatibility.md)、[Masker 退役审计](masker_retirement_audit.md) |
| 历史接口与路线研究 | [接口审计](interface_evolution.md)、[中继研究](../research/relay_enhancement_feasibility.md)；当前待办以统一计划为准 |

旧 reference 路径的跳转文件只为保留链接；旧 DSL、签名及验证档案见 [archived](../archived/README.md)。研究中的拟议接口不可用于当前生产包。
