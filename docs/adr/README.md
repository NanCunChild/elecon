# 架构决策索引

日常开发先读[现行架构](../architecture.md)，作者从 [Wiki](../wiki/README.md) 开始；实现、待办和验收统一维护在[实施计划](../planning/implementation.md)。ADR 用于解释重要选择的原因与替代关系，**无需按编号逐篇阅读**。

`Accepted` 表示决策接受，不表示接口、真机或人工签收已完成。旧 ADR 的局部规则按后续明确决定替代，其余有效语义继续由现行架构和版本化契约承接；本轮不批量修改历史状态。默认 owner 为 NanCunChild，人工审阅需独立证据。

## 按问题追溯

| 问题 | 决策入口 |
|---|---|
| 当前重构：普通 JS、统一运行/错误与文档收敛 | [081](adr_081_script_runtime_consolidation.md) |
| 长期网页 JS、自动操作、所有能力首页入口与验证码/MFA | [080](adr_080_trusted_script_extensibility.md)；接口分片实施 |
| 受信源码、身份、数据与旧路径边界 | [034](adr_034_trusted_school_scripts.md)、[035](adr_035_script_credential_identity.md)、[041](adr_041_current_architecture.md) |
| 卡片来源、普通请求与页面 | [043](adr_043_card_layout_and_overrides.md)、[046](adr_046_triggered_script_requests.md)、[066](adr_066_feature_sources_and_account_state.md)；有限入口由 080 扩展 |
| 账号、认证恢复与网页旧模式 | [068](adr_068_script_interaction_and_recovery.md)、[072](adr_072_saved_password_recovery.md)、[073](adr_073_packaged_web_content.md)；长期目标由 080 扩展 |
| APPTunnel 与声明连接 | [062](adr_062_app_tunnel_selection.md)、[077](adr_077_declared_account_credential_reuse.md)、[078](adr_078_script_tunnel_accounts.md) |
| 社区与消息 | [052](adr_052_community_accounts_and_chaoxing.md)、[061](adr_061_message_history_and_storage.md) |
| SDK 文案、条件及学校标题 | [070](adr_070_script_localization.md)、[071](adr_071_script_query_controls.md)、[082](adr_082_script_query_forms.md)、[083](adr_083_deferred_query_fields.md)、[079](adr_079_school_presentation_and_titles.md) |
| 原生平台 AI | [069](adr_069_android_app_functions.md)、[074](adr_074_android_app_functions_implementation.md) |
| 后续匿名增强与中继 | [042](adr_042_providers_pages_enhancements.md)，未实施部分仍为 Proposed |
| V1 整理与退役 | [065](adr_065_repository_cleanup.md)、[兼容维护边界](../reference/legacy_compatibility.md) |

电话黄页与原生拨号见 [084](adr_084_phone_directory.md)；应用快捷方式与系统 AI 页面入口见 [085](adr_085_feature_shortcuts.md)。

门户入口与详情模板见 [086](adr_086_portal_pages.md)，前台二维码续订见 [087](adr_087_foreground_card_refresh.md)，书目检索见 [088](adr_088_library_search.md)。

学校休息段与个人课表隔断见 [089](adr_089_schedule_break_segments.md)。

表单缓存与可选条件见 [091](adr_091_query_form_cache.md)。

Android 前台缓存课表小部件见 [090](adr_090_schedule_widgets.md)。

本地空调绑定、扫码与独立状态见 [092](adr_092_climate_binding_and_controls.md)。

有限红外方案与无回读控制见 [093](adr_093_finite_infrared_climate.md)，本地只读消息同步与通知见 [094](adr_094_local_message_sync.md)；两项均为 **Proposed**，未增加现行 SDK/权限或后台执行能力。

其他领域决定按能力名查本目录文件或契约历史；所有 ADR 正文与编号保留。2026-11-04 收敛前的逐项 Decision/Landing/Security signoff 状态见[完整状态快照](../archived/2026-11-04/docs/adr/README.md)，不用过去一次测试数量代替当前实现证据。

受保护存储不可用时保留数据及显式重试见 [095](adr_095_protected_store_recovery.md)，替代 060 的自动清除策略；不因此启用后台同步。

系统教室查询的明确楼栋、同来源目录与学校时区校验见 [096](adr_096_system_classroom_query_inputs.md)。

## 历史记录与维护原则

ADR-000–033 已退出新开发总纲，原路径留跳转，正文和当时批准事实见[旧索引](../archived/2026-10-31/docs/adr/README.md)。ADR-021 是历史预留，编号不回收。

新增 ADR 只记录未被已有决定覆盖的架构、契约含义或权限选择；同一决定下的内部重构、普通页面与学校协议修复不另造一篇。重要决定保持简短，说明问题、取舍、版本/迁移和验证边界；实现流水写入带日期的证据记录，不不断追加进架构正文。
