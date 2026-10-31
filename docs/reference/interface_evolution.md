# 模板与接口演进审计

> 2026-10-31 工作区观察与实现规划。本文未修改运行时；水电、空调、SDK 5 与 ADR-040 的观察包含任务开始前已有的未提交工作，不是本轮新增实现。当前架构见 [ADR-041](../adr/adr_041_current_architecture.md)，拟议 provider、页面与增强包设计见 [ADR-042](../adr/adr_042_providers_pages_enhancements.md)。以下候选接口不代表现有 SDK 已支持。

兼容性的目标是让页面依赖明确的业务契约，让学校包和增强包通过宿主提供同一能力。优先改进来源选择、输入校验和页面状态复用，再扩充论坛、图书检索等领域；不以扩大 `generic.section` 或继续堆叠首页条件分支替代领域接口。

> 后续进度：本表保留实施前观察。逐能力来源绑定、有限卡片及本地编辑已由 [ADR-043](../adr/adr_043_card_layout_and_overrides.md) 实施；完整参数/领域/PageDefinition 重构未完成。

## 1. 实施前代码观察与改动方向

下表行号对应上述工作区快照，文件链接指向当前源码；后续改动以符号名称定位。

| 代码位置 | 已有行为或缺口 | 建议方向 |
|---|---|---|
| [ScriptRegistry](../../client/lib/core/scripts/registry.dart) 第 27、59、91 行 | 安装列表倒序，`provider` 取首个匹配；安装或更新会改变顺序 | 主包与增强包显式绑定能力，安装顺序不决定业务来源；请求开始后固定 provider 与 digest |
| [SessionController.runCapability](../../client/lib/session/session_controller.dart) 第 446 行 | 通用入口优先选择当前学校脚本 | 保留统一入口，提取 provider 解析；旧 V1 路径作为兼容执行器接入，不混用信任机制 |
| [trustedScriptCapabilities / refreshHomeData](../../client/lib/session/script_session.dart) 第 304、357 行 | 对全部启用包做能力并集，对各包的 preload 分别执行 | 由已绑定 provider 计算能力可用性、预加载和缓存策略，避免重复查询与被遮蔽包仍后台执行 |
| [ScriptCapability.fromJson](../../client/lib/core/scripts/manifest.dart) 第 222 行 | 强制 schema 等于 `elecon.<capability id>` | registry 明确输入、输出和版本；初期保留同名映射，确有复用需求再放开，不宣称现已支持任意映射 |
| [TrustedScriptRuntime.run](../../client/lib/core/scripts/runtime.dart) 第 84 行 | 输出使用版本化 validator；普通 params 仅有 JSON 编码与大小限制 | 补齐通用输入 schema 和执行前校验；command 的专门校验继续保留 |
| [首页装配](../../client/lib/ui/home/home_page.dart) 第 229 行 | 逐项硬编码能力对应卡片 | 固定客户端 Feature/Page 注册，声明必需及可选能力、路由参数、卡片与页面入口 |
| [能力区](../../client/lib/ui/home/capability_sections.dart) 第 126、362、1362 行 | `_CachedSection` 混合缓存和 Widget 生命周期；课表、借阅集中在首页 | 提取 QueryController 与领域 Repository，供首页摘要、独立页和详情共同使用 |
| [noticeListFromDynamic](../../client/lib/ui/home/schema_decode.dart) 第 30 行 | 仅返回 items，丢失 schema 已有的 page、cursor、hasNext、total | 生成完整 decoder；分页元信息不能在视图转换时消失 |
| [通知详情](../../client/lib/ui/home/notice_detail_page.dart) 第 74 行 | 列表项只携 id/url，详情重新选择默认 provider | 列表、详情共享来源绑定与实体命名空间，防止增强包列表误查主包详情 |
| [西电能力入口](../../school-scripts/xidian/src/index.js) 第 42 行；[脚本会话](../../client/lib/session/script_session.dart) 第 681 行 | `generic.section` 兼作登录，成功后又被用作空调同步触发信号 | 后续增加独立认证生命周期；保留旧入口兼容，停止从展示数据域猜测认证事件 |

### 凭据边界是增强包的前置设计

[SDK 类型](../../contract/script-sdk/types.d.ts) 第 2、68 行与 [ScriptCredentials](../../client/lib/core/scripts/credentials.dart) 第 63 行表明：SDK 2–5 的 namespace 是寻址方式，不是访问权限。受信包可访问当前授权身份内的其它凭据 namespace。

因此，主包和增强包采用不同 namespace **不能实现凭据隔离**。无凭据增强包需要新的宿主授权配置与 SDK 门，在运行时不提供凭据及浏览器能力；旧 SDK 保持原信任语义，不能把旧包默认为低权限包。跨包调用或共享认证必须另有明确授权，不由“依赖主包”自动授予。

## 2. 接口名称与责任

| 名称 | 确定含义 | 不承担的责任 |
|---|---|---|
| Capability | 有确定输入、输出和副作用语义的业务操作 | 不是页面名或安装包名 |
| Schema | 某版本的数据结构与字段语义 | 不决定执行者、缓存位置或界面布局 |
| Provider | 某个包对能力的具体实现，绑定批准 digest、身份和支持版本 | 不因最新安装就拥有最高优先级 |
| 主学校包 | 学校认证与常用能力的默认集合 | 不把全部凭据自动转授增强包 |
| 增强包 | 给明确能力增加可选 provider，或按显式规则组合数据 | 不静默替换主包、不无限互调 |
| PageDefinition | 宿主固定页面及路由、依赖能力、呈现规则 | 不接收学校下发的 Widget tree |
| EntityRef | 身份、数据集/来源、实体类型与局部 ID 的组合 | 不把不同来源的同一个字符串 ID 当作同一实体 |
| Query / Command | 按业务副作用区分读取与写入 | 不按 HTTP GET/POST 推断；查询可能使用 POST |

建议宿主内部形成 `resolve → validate input → execute → validate output → cache → present` 的统一查询流程。解析结果固定 provider、digest 与身份；页面通过类型化查询描述符调用，不自行携带凭据、任意 URL 或选择学校协议。此流程是实现方向，不是本轮新增 API。

来源组合第一版只实现“为某 query 显式选择 provider”。通知 list/detail、教室 buildings/available 等共享实体标识的能力应作为绑定组；多源聚合另行规定实体键、去重、排序、部分失败与来源显示，不能自动拼接任意数组。

## 3. 页面与领域契约

| 页面 | 可复用的当前能力 | 新增或需要澄清的语义 |
|---|---|---|
| 独立课表 | `schedule.week`、`term.list`、`calendar.academic` | 摘要与完整页共享状态；教学周与日历日分开；学校开学和调课规则由脚本处理 |
| 课程标准或课程大纲 | `course.catalog` 可作目录 | 用户所称“课标”也可能指课表。保留两条领域路径；若指课程标准，拟新增 `course.detail` / `course.syllabus`，不占用 `schedule.week` |
| 图书查阅 | `library.loans` 仅代表个人借阅 | 拟新增书目搜索、书目详情、馆藏复本；区分书目 ID、复本条码、借阅记录 ID；公开检索与个人借阅分开 |
| 论坛 | 可复用固定列表、分页、详情、有界正文组件 | 拟新增 board/thread/reply 数据模型；不能将帖子伪装成 notice；发帖、回复、删除属于 command，首版可只读 |
| 通知增强 | `notice.list/detail` | 列表与详情同源、撤回与过期、来源显示、可选增强与回源；不能缓存一次后永远保留已撤回正文 |
| 空教室增强 | `classroom.buildings/available` | 标识命名空间一致；查询与缓存明确日期、时段、校区/楼栋及权限范围；无课不自动等于可进入或可预约 |

渲染模板应复用结构而保留领域语义：分页列表可以服务论坛和图书搜索，但帖子权限、借阅状态、课表时段仍由各领域模型表达。`generic.section` 保留长尾只读展示，不承接论坛关系、分页协议、认证或控制。

## 4. 应先确定的通用语义

1. **版本**：包版本、SDK 版本、输入/输出 schema 版本、页面版本和增强包依赖范围分别管理。宿主按实际支持的版本集合或显式转换裁定兼容，不用“都是 1.x”代替检查，也不用包版本判断数据新鲜度。
2. **查询结果**：拟在业务 data 之外提供宿主验证的 provider、schemaVersion、来源路径、源数据获取时间、TTL、stale 与完整性。现有 [CapabilityRun](../../client/lib/core/adapter_service.dart) 第 85 行只有 data 和失败分档，不具备上述完整元信息。
3. **错误**：稳定 code/kind 区分认证、权限、网络、限流、源站、解析、版本和取消；安全展示文案与可选 retryAfter 独立表达。保留任意脚本异常文本净化，不能原样把上游错误或凭据显示给用户。
4. **分页**：明确 offset 或 opaque cursor；cursor 绑定 provider、查询条件、排序与身份。缺 total 表示未知；当前条数不是总数；预算不足或截断需显式表达，不能返回假完整集合。
5. **缺失**：字段缺失表示未提供；空集合表示完成查询后零条；失败与未完成不能冒充空集合；unknown 不等于 false 或 0。
6. **时间**：日历日、带时区的瞬间、墙钟时间与节次分开。[schedule.week](../../contract/schema/schedule.week.schema.json) 的 timeStart/timeEnd 现同时容纳时间与节次；[library.loans](../../contract/schema/library.loans.schema.json) 的仅日期来源被映射为 UTC 时刻。新版应消歧，旧字段通过显式兼容转换保留，不能悄悄改变同一字段的含义。
7. **缓存**：键包含身份、provider/digest、能力版本和规范化参数；中继命中不能重置源数据时间。当前 [ScriptDataCache](../../client/lib/core/scripts/data_cache.dart) 第 46 行已有包/digest/参数隔离，但策略仍依赖 manifest.home；拟将 query policy 与首页装配分开。
8. **命令**：复用 ADR-040 的专用确认、一次性授权和取消原则，不把论坛或续借塞入 climate 类型。超时的未知结果不能自动重发或跨 provider 重试；具体 command 仍需领域约束与验证。

## 5. 模板与迁移切片

当前 [HTTP 模板](../../adapters/_template/trusted/http/index.js) 显式读取共享 `campus.session` Cookie，其 [manifest](../../adapters/_template/trusted/http/manifest.json) 为 SDK 2。它应继续作为受信学校会话示例，不能直接改名为无凭据公网增强模板。后续模板按学校认证包、无凭据公开 provider、领域查询模块区分，使用同一组契约夹具。

| 顺序 | 交付范围 | 验收要点 |
|---|---|---|
| 1 | ADR-042 细化术语、授权配置、绑定与版本迁移 | 现状和提案分开；旧 SDK 不被重新解释；新包不凭名称获得低权限保证 |
| 2 | registry 单源生成输入 validator、完整 decoder 与类型 | 非法入参执行前拒绝；分页元信息保留；已有包和历史输出版本夹具通过 |
| 3 | QueryController、固定 PageDefinition；先独立课表页 | 首页和独立页共享结果与取消；切身份清除旧数据；页面不嵌入学校协议 |
| 4 | 显式主包/provider binding 与能力绑定组 | 安装、更新不抢绑定；来源组一致；迁移后的默认选择可见、可撤销 |
| 5 | 无凭据公开通知增强试点 | 未选包不预加载；不能枚举主身份凭据；list/detail 同源；禁用后恢复主包；缓存和直连来源清楚 |
| 6 | 图书检索与论坛只读模型及页面 | 搜索/分页边界、实体引用、未知与空态确定；不冒充现有借阅或通知能力 |
| 7 | 按领域推进写操作、身份增强及旧入口清理 | 独立命令授权与人工审阅；替换 generic.section 登录约定后再移除兼容层 |

每片独立提交和回滚。组合测试至少包含：两个 provider 返回同名但不同实体 ID、主包更新不抢能力、列表打开后 provider 被禁用、旧 SDK 行为不漂移、未选增强包不查询、无凭据包不能读凭据、切身份后的晚到结果不写缓存。接口与身份边界的自动测试不能替代人工安全审阅。
