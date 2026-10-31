# 当前 ADR 状态索引

新开发先读 [ADR-041](adr_041_current_architecture.md)与相关 ADR-034 起的有效决定。`Accepted` 表示决策接受，不代表代码、真机验收或人工安全签收完成。默认 owner 为 NanCunChild，安全签收必须有人工证据。

ADR-000–033 已废弃为新开发总纲，正文移至 [archived](../archived/README.md)，旧路径只留跳转。共享语义和未迁移 V1 约束由 [ADR-041 §3](adr_041_current_architecture.md#3-从历史-adr-继承的有效约束)及[兼容边界](../reference/legacy_compatibility.md)承接。历史接受/延期/签收状态见[旧索引快照](../archived/2026-10-31/docs/adr/README.md)，不批量改写为“代码已退役”。

现行脚本执行与验收见 [trusted_scripts](../planning/trusted_scripts.md)；后续页面/增强包/中继切片见 [platform_evolution](../planning/platform_evolution.md)。

| ADR | Decision | Landing | Security signoff | Blocker / source |
|---|---|---|---|---|
| [034](./adr_034_trusted_school_scripts.md) | Accepted（2026-10-29 所有者会话授权） | 已实现；2026-10-30 增加西电脚本与 STRING_ROPE 桥接修复，见 [计划](../planning/trusted_scripts.md) | 待人工复核与平台真机 | 新源码脚本路径显式覆盖 #1/#4/#5 旧约束；没有声称退役全部 V1 |
| [035](./adr_035_script_credential_identity.md) | Accepted（2026-10-29 所有者检查与修复授权） | SDK 2 与多凭据行为见[阶段记录](../planning/trusted_scripts.md) | 待人工复核与平台真机 | 细化 ADR-034；SDK 1 保留预览兼容 |
| [036](./adr_036_card_account_identity.md) | Accepted（2026-10-30 所有者确认） | 已实现可选卡号，回归见受信脚本计划 | 待真机及人工审阅 | 不用学号/openid/占位值伪造卡号；不新增支付/换卡能力 |
| [037](./adr_037_script_input.md) | Accepted（2026-10-30 所有者要求通用输入接口） | SDK 3 固定输入表单已实现，核心回归见计划 | 待真机及人工审阅 | SDK 2 凭据寻址保留，不增加任意 UI/原生能力 |
| [038](./adr_038_script_home_cache.md) | Accepted（2026-10-30 所有者本轮要求） | SDK 4 首页缓存、预加载与静默刷新已实现 | 待真机及人工审阅 | 当前学校本地 H/S/M 保护、时间与参数隔离，后台不弹认证界面 |
| [039](./adr_039_script_browser_busy.md) | Accepted（2026-10-30 所有者本轮要求） | SDK 4 固定登录遮罩与 IDS 收尾优化已实现 | 待真机及人工审阅 | 脚本只控制 busy 布尔值，取消继续可用，保留业务验证 |
| [041](adr_041_current_architecture.md) | Accepted（本轮文档重整授权） | 文档基线与归档 | 不新增实现签收 | 承接有效约束，旧总纲退出主线 |
| [042](adr_042_providers_pages_enhancements.md) | Proposed | 未实现 | 后续核心/权限实施须人工审阅 | provider、独立页面、增强包与中继切片 |

ADR 编号不回收：021 仍是历史预留。更新决策、实现与签收时分别修改对应列，不用自动测试替代人工复核。
