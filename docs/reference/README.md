# 当前参考文档

先读[当前架构](../architecture.md)，再按任务选资料。

| 任务 | 文档 |
|---|---|
| 各功能核心/脚本/契约归属及抽象欠账 | [core_script_boundaries](core_script_boundaries.md) |
| 学校源码开发、安装与打包 | [trusted_scripts](trusted_scripts.md) |
| 学校实现与验收状态 | [实施记录](../planning/trusted_scripts.md) |
| 首页长按编辑、卡片尺寸及同名覆盖 | [使用说明](card_layout_and_overrides.md)、[ADR-043](../adr/adr_043_card_layout_and_overrides.md) |
| 新页面、模板、标准接口与增强包 | [接口审计](interface_evolution.md)、[ADR-042 提案](../adr/adr_042_providers_pages_enhancements.md) |
| 通知/教室/水电中继 | [研究](../research/relay_enhancement_feasibility.md)、[实施切片](../planning/platform_evolution.md) |
| 旧代码兼容维护 | [legacy_compatibility](legacy_compatibility.md)、[Masker 退役审计](masker_retirement_audit.md) |
| 浏览器认证观察 | [browser_auth_trace](browser_auth_trace.md)、[西电认证对照](xidian_pda_auth_comparison.md) |
| Chaoxing 扫码签到、配置/位置与 Profile 多平台登录 | [可行性考察](../research/chaoxing_checkin_feasibility.md)（早期研究；当前实现以 [ADR-055](../adr/adr_055_checkin_locations_and_diagnostics.md)、[ADR-058](../adr/adr_058_foreground_device_inputs.md) 和[边界表](core_script_boundaries.md)为准） |
| 西电能力对照及探针 | [xidian_script_update](xidian_script_update.md)；V1 smoke runbook 已[归档](../archived/2026-11-02/docs/reference/xidian_smoke_runbook.md) |
| 依赖许可 | [trusted_scripts_dependencies](trusted_scripts_dependencies.md) |
| 发布与日志 | [release_workflow](release_workflow.md)、[cross_end_logging](cross_end_logging.md)（按执行路线选择） |
| 既有成绩字段历史 | [绩点字段迁移档案](../archived/2026-11-02/docs/reference/gradepoint_ownership_landing.md)（当前消费状态见[边界表](core_script_boundaries.md)） |

[script SDK](../../contract/script-sdk/types.d.ts)、[源码包 schema](../../contract/script-package.schema.json)、[领域 schema](../../contract/schema/)和[能力 registry](../../contract/capability/registry.json)是实际机器契约。研究中出现的拟议接口尚不可用于安装包。

旧 requestGraph、Broker、Masker、签名发布规格及签收记录已迁至 [archived](../archived/README.md)。原参考路径只留跳转，继续修改旧实现前查兼容边界与历史原文。
