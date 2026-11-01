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
| [040](./adr_040_energy_and_trusted_climate.md) | Accepted（2026-10-31 所有者确认） | 领域契约与固定卡片已实现；action 已由 046 废除；见受信脚本计划 | 待人工实现审阅/真机 | Android 控制；V1 门不放宽，研究生不新增能力 |
| [041](adr_041_current_architecture.md) | Accepted（本轮文档重整授权） | 文档基线与归档 | 不新增实现签收 | 承接有效约束，旧总纲退出主线 |
| [042](adr_042_providers_pages_enhancements.md) | 部分由 043 接受，其余 Proposed | 同名覆盖与卡片首片；完整平台未实现 | 待人工实现审阅 | 独立页面、匿名增强与中继仍待实施 |
| [043](adr_043_card_layout_and_overrides.md) | Accepted（本轮所有者要求落地） | 同名覆盖、SDK 6 cards、长按编辑/排序/有限缩放已实现 | 待真机手势及人工核心审阅 | 回归见 ADR 正文，未部署中继 |
| [044](adr_044_local_profiles.md) | Accepted（本轮多 Profiles 授权） | 独立会话/存储与设置行已实现 | 待人工核心审阅/真机 | 不共享安装授权与凭据 |
| [045](adr_045_script_qr_scanner.md) | Accepted（本轮扫码接口授权） | SDK 8 前台二维码接口已实现 | 待人工权限审阅/真机 | 扫描不等于提交签到 |
| [046](adr_046_triggered_script_requests.md) | Accepted（2026-11-01 所有者废除 action 授权） | 统一普通请求，空调触发发送后查询；见受信脚本计划 | 待人工核心审阅/真机 | 取代 040 action 与额外确认；旧包显式更新，V1 不变 |
| [047](adr_047_feature_pages_and_card_qr.md) | Accepted（本轮功能查看授权） | 原生查看页、周课表/今日时间线、独立校园卡二维码；空教室目录由脚本内置 | 待真机及核心人工审阅 | 无消费学校不伪造余额；二维码禁止持久缓存 |
| [048](adr_048_schedule_navigation_and_segments.md) | Accepted（本轮课表交互授权） | 周预览、滑动切周、学校时间分段及重叠覆盖已实现 | 待人工契约审阅/真机 | schedule.week 1.1，保留 1.0 校验 |
| [050](adr_050_faculty_search.md) | Accepted（本轮教师查询授权） | 官网分页脚本、原生检索与同源详情已实现 | 待人工契约/网络审阅 | 新增 faculty.search 1.0；不预加载/不读取凭据 |
| [051](adr_051_forum_and_messages_reservation.md) | 入口预留 Accepted；后续由 052 细化 | 历史四导航/占位首片；当前为按能力显示 | 后续认证/网络仍待人工审阅 | 保留规划历史，当前状态见 052 |
| [052](adr_052_community_accounts_and_chaoxing.md) | Accepted（本轮服务接入授权） | 睿思账号、学习通增强包、SDK 9 有界前台 WebSocket 与动态 Tab | 待人工核心/网络审阅与真实账号/真机 | 无历史私信/推送；签到限定无额外挑战的 QR 活动 |
| [053](adr_053_provider_updates_and_service_cancellation.md) | Accepted（修复课表与独立服务） | registry v3 旧绑定恢复、基础包契约升级、单次调用取消；社区包手动导入 | 自动回归与设备结果另记；核心人工审阅待完成 | 保留批准 digest 和显式覆盖选择，不提升 namespace 权限 |

ADR 编号不回收：021 仍是历史预留。更新决策、实现与签收时分别修改对应列，不用自动测试替代人工复核。
