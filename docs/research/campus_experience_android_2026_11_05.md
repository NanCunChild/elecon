# 校园页面体验与 Android 能力研究

日期：2026-11-05。状态：**研究与实施建议，未实施本轮产品变更，未接受新的 SDK/权限契约**。代码基线为 `a839856`，客户端 `0.8.2+13`。任务状态只在[统一实施计划](../planning/implementation.md)维护；本文记录证据、方案及验证边界。

本轮按用户授权读取仓库、并行研究并做 ADB 只读检查。没有请求真实学校业务、拨打电话、发送消息、发射红外或操作真实空调；没有安装 APK、修改系统设置或读取凭据库。代码、现有回归、设备观测与方案可行性分别记录。

## 结论与拆分

| 用户需求 | 已有基础 / 主要差距 | 建议范围 |
|---|---|---|
| 学习通知概要、卡片走马灯 | 学习通已有 summary；列表不限行，首页仅第一条标题 | 复用现有通知数据，固定高度逐条轮播概要，全文留详情 |
| 空教室默认日期与教学楼，校区不限 | 西电脚本默认南校区并过滤楼栋 | 学校脚本取消校区条件，完整展示南北教学楼；核心通用折叠可选条件 |
| 筛选本身缓存 | 业务结果和已提交参数已有缓存，表单定义/延迟选项/草稿不持久 | 补独立表单缓存 ADR，复用身份、来源及存储生命周期 |
| 午间、晚餐小隔断与空闲提示 | 正式节次来自脚本；核心有兜底轴及无标签空档压缩 | 修复区间相交判断；具名休息段由脚本提供，新增版本化语义 |
| 电话黄页摘要直接拨号、详情减负 | 首页纯文本；全局来源复制按钮、长下拉菜单仍在 | 沿 ADR-084 做自适应号码行、有限弹窗与小图标按钮 |
| 空调扫码、绑定卡片和温控 | 已有扫码宿主与网络控制；西电仍手输绑定 | 先复用现有 SDK 完成网络页；红外另做契约与原生端口 |
| 群聊右侧最新消息时间 | 已有 lastMessageAt，UI 未使用 | 直接使用既有字段；后台同步/通知独立设计 |
| HyperOS 4 快捷方式 | 原生实现缺成功回调与失败分类；当前设备非 HyperOS 且装旧版 | 先完善可观测性，另在对应系统/版本验证 |
| 课表桌面小部件 | 有课表缓存与入口，无 AppWidget 实现 | 先做本地缓存只读展示，需要桌面数据暴露与生命周期 ADR |
| 周缩略图“本周”挤占 | 本周额外插入一行文字 | 改常驻描边，选中态另用填充，保留读屏语义 |

## 学习通知

[学习通 notices.js](../../school-scripts/xidian-chaoxing/src/notices.js) 的 `noticeList` 已返回 `content` 与前 240 字符的 `summary`。这里的概要是文本截取，不是语义摘要；第一片可先复用，再按学校内容清洗前缀、重复标题与多余空白，无需引入模型服务。

[NoticeCard](../../client/lib/ui/home/result_cards.dart) 当前首页摘要取第一条标题，未消费 summary、没有轮播；二级列表拼接来源、类别、日期和 summary，却没有限制标题/摘要行数。学习通包没有独立 `notice.detail`，因此不能为了缩短列表而删除列表数据中的 content，[通知详情](../../client/lib/ui/home/notice_detail_page.dart)仍需它。

建议首页一次显示一条：标题至多两行、概要至多两行，来源与日期轻量显示；在实际可用高度下减少行数。走马灯采用逐条概要轮播，不滚动整篇全文。点击当前项打开同一来源的该条详情，标题/卡片空白仍可进入完整列表。列表也限定概要行数。轮播仅在可见且前台时运行，单条不启动计时；手动交互、读屏或减少动画模式下暂停/静态展示；更新按通知 ID 保持位置，切来源/身份清空。沿 [ADR-066](../adr/adr_066_feature_sources_and_account_state.md) 与 [ADR-086](../adr/adr_086_portal_pages.md)实现，不新增契约。

## 空教室筛选与恢复

### 日期、楼栋与校区

[query_controls.js](../../school-scripts/xidian/src/query_controls.js) 第 65–68 行默认南校区、据校区筛选楼栋，第 87–109 行输出日期、校区、教学楼及六项可选条件。[包内目录](../../school-scripts/xidian/src/classroom_directory.js)本来已有南校区 27 栋、北校区 9 栋及楼内分区。

建议学校脚本移除 campus 控件及 building 对它的依赖，教学楼选项包含完整目录，显示名附校区以区分相似名称。校区名称仍可作为结果/选项信息。核心不能硬编码西电的字段 ID、校区代码或楼栋名单。

必须同时处理真实请求与旧选择：[query_filters.js](../../school-scripts/xidian/src/query_filters.js)会提升 `filters.campus`，[academic.js](../../school-scripts/xidian/src/academic.js)会检查校区匹配并发送 `XXXQDM`。不能只隐藏选择器、继续暗中限制南校区。更新包时清除旧表单/旧参数，新的交互请求始终不带校区筛选；旧版本输入如仍保留，应明确兼容或拒绝策略，不能无声忽略调用者明确传入的条件。

默认仅常显日期、教学楼，其他条件收进“更多条件”。可先采用通用的“必填常显、可选折叠”，复用已有 required 语义；若要让作者独立决定展示优先级，须先为布局提示另定版本，不能在核心识别业务字段名。恢复已应用高级条件时显示数量及摘要，不能让用户看不到实际筛选。

折叠不改变字段的必填校验，也不自动减少请求：`query_form_dialog.dart` 第 191/208 行仍会安排延迟字段加载，西电 roomTypes 的解析实际调用一次完整空教室查询。建议无已应用值的可选项在展开时再解析，有效依赖缓存命中则复用；恢复已有可选选择时必须核验或允许显式清除，不能因折叠而忽略旧条件。视觉简化和延迟加载应分别验证。

当前脚本还默认“现在起 60 分钟”。如果只显示日期与楼栋，建议初始不应用时段、容量、类型等额外条件，以选定楼栋的日程浏览为默认；用户主动展开时才选择时段。仅隐藏控件却保留默认时段，会继续产生不易理解的结果。教室空闲仍按源站节次证据计算，课间或夜间保持未知。

“南北全部区域”有两种范围：完整楼栋选择器，或一次查询全部楼栋。当前 `classroomAvailable` 要求单楼栋，输出 coverage 明确不是全校查询。本研究默认前者；若要求后一种，还需设计逐楼栋的有界请求、分页、取消、部分失败及覆盖说明，不能直接并发扫 36 栋或宣称完整结果。

### 缓存三类状态

[ClassroomSection](../../client/lib/ui/home/classroom_section.dart)已经从业务缓存恢复已提交参数，[CachedQuerySection](../../client/lib/ui/home/query_section.dart)也隔离来源与身份。但 [QueryFormDialog](../../client/lib/ui/home/query_form_dialog.dart)创建时重新加载，[内联表单](../../client/lib/ui/home/script_query_controls.dart)每次执行 `query.controls`，未提交草稿只留在 Widget State。于是结果可能还在，选项与草稿仍重新加载。

[ADR-082](../adr/adr_082_script_query_forms.md)与 [ADR-083](../adr/adr_083_deferred_query_fields.md)明确当前表单元数据不写业务缓存。应补一个独立表单缓存决定，分开保存：

1. 基础字段定义、静态选项及原始取得时间。
2. 延迟选项及其依赖指纹，如日期、楼栋；不同依赖不能混用。
3. 已应用值与未提交草稿；离页保留草稿，取消编辑仍可恢复已应用值。

缓存按 Profile、学校、包 ID/批准 digest、目标能力、表单版本、语言及依赖参数隔离；登录/退出/来源变更采用业务身份失效机制，不能仅靠进程内代际作为跨重启身份。使用已有受保护存储，M 档仍只有内存。表单缓存和业务结果分别有大小/时效限制，读取失败可恢复，旧数据不得跨身份显示。

返回页面先恢复有效表单与选择，必要时再更新；静态楼栋不应重复取网。过期动态选项标明待核验，更新失败保留可见旧值但不把非法选项当可提交。日期与实时默认值需区别“用户已选值”和“脚本默认值”，不能因缓存冻结昨日的默认日期。学校日期仍由脚本决定，不由宿主猜时区。恢复草稿或元数据不自动发起业务查询。

## 课表时间、空闲隔断与本周标记

正式节次在学校 [academic.js](../../school-scripts/xidian/src/academic.js) 的 `TIMES`（第 25–36 行），通过 `schedule.week.timeSegments` 输出；当前西电配置的午间间隙为 12:00–14:00，晚间为 17:30–19:00。这是脚本现有配置，不能当成本轮真实学校作息验收。

核心 [schedule_view.dart](../../client/lib/ui/home/schedule_view.dart) 的 `_ScheduleAxis` 消费这些分段，但 minimum/maximum 仍以 08:00–18:00 或 12 节兜底；这些值也参与有分段时的外沿范围计算。建议有合法分段时仅以脚本分段与实际课程扩展轴，旧数据缺分段时才保留明确的展示兜底。宿主可以决定像素高度，不能决定学校午餐/晚餐时间。

当前全部非教学且未占用间隙统一压为 `12.0 * scale`，没有空闲标签。并发现一个应先修复的问题：第 1011–1012 行只检查课程起点或终点落入间隙；一门课完整跨过该间隙时会漏判。正确判断须使用半开区间相交：`course.start < gap.end && course.end > gap.start`。

仅绘制通用间隙可以沿 [ADR-048](../adr/adr_048_schedule_navigation_and_segments.md)消费相邻分段；但要准确区分午餐/晚餐，现有 timeSegments 只表达上课段，需新增可选休息段语义、版本及迁移。脚本返回起止和标签，宿主画细隔断；不得以固定时刻或“最大两个间隙”猜餐段。空闲标记按当天实际课程判断，遇跨间隙课程仍显示课程；整个周视图的通用休息提示不能保证每天都无课。

这里的“空闲”应表示当前已加载个人课表无排课，不是空教室可使用。[ADR-067](../adr/adr_067_classroom_availability_intervals.md)要求教室课间证据不足时保持未知；两种页面不能共享错误的“补空闲”推断。

周选择器第 373–380 行额外插入“本周”文字，挤占缩略图。直接移除可见文字，以常驻细描边/角标表示本周、背景填充表示正在查看的周；浏览别周时两者都能识别。现有 Semantics 的本周标签保留，必要时提供 Tooltip。无需新 schema。

## 电话黄页

[PhoneDirectorySection](../../client/lib/ui/home/phone_directory_section.dart) 第 150–165 行把前三个条目拼成纯文本摘要；`_recentIds` 只是页面内搜索匹配记录，不是持久化常用/拨打历史。当前脚本目录前部已有常用号码，可优先沿用来源顺序，避免核心根据中文分类名挑选。若以后提供收藏或最近拨打，需保存稳定条目 ID 并按来源隔离，不能把搜索匹配宣称为使用频率。

推荐有限高度摘要：

| 宽度 | 排版 | 操作 |
|---|---|---|
| 全宽 | 根据可用高度显示 2–3 个号码行，名称在前、号码独立对齐；同名条目附校区 | 点击该行/号码打开对应系统拨号页；标题或空白进入目录 |
| 半宽 | 一个名称作主标题、电话作副标题，紧凑电话图标 | 点击号码区域拨号，保留独立详情入口 |
| 大字号/极窄 | 减少条目数，名称省略但读屏可读全名，号码优先完整展示 | 保留可点击区域，不把多号码拼成无法识别的文字 |

复用现有 `openPhoneDialer`，维持 [ADR-084](../adr/adr_084_phone_directory.md) 的 `tel:` 系统电话应用流程。这里的“直接点击拨打”落实为直接打开该号码的拨号界面，由系统继续呼叫；不是新增静默通话权限。点击号码不能同时触发 [SectionCard](../../client/lib/ui/home/section_card.dart)外层跳页。

详情第 285–289 行的“复制目录来源链接”按钮可删除，契约中的目录来源仍保留。每个电话第 370 行的 `sourceUrl` 与核对日期继续可见；若将链接改成可打开入口，应只处理现有标准 HTTPS 来源，不扩成脚本任意 URI 启动能力。

分类/部门由 `DropdownButtonFormField` 改成高度受限、可滚动的选择弹窗，包含“全部”、当前选中态，类别较多时支持本地搜索；关闭不改变选择。复制按钮缩小图标及视觉留白，保留足够触控范围和 Tooltip。验证全宽/半宽、320px、两倍字号、中英文/RTL、长部门名和 15 位号码，拨号失败仍可复制。无需修改电话领域契约。

## 空调：网络页复用，红外另定语义

### 已有能力

[energy_climate_sections.dart](../../client/lib/ui/home/energy_climate_sections.dart)已有配置、设备选择、开关/模式/温度/风速/扫风和单次控制后查询。[西电脚本](../../school-scripts/xidian/src/climate.js)使用 15 位 IMEI 手输绑定，状态核验成功才保存；学校实现目前只保存一台，不能因 schema 支持列表就声称已有多台绑定。

宿主 SDK8 已有 [scanQRCode](../../contract/script-sdk/types.d.ts)，[扫码页面](../../client/lib/ui/scripts/script_scanner_page.dart)和 `mobile_scanner` 依赖也已存在。学校包可以声明 scanner、升版并重新授权 digest，用脚本决定扫码/手输及二维码解析；不需要再加入一套扫码库，扫描出的 URL 不能自动作为任意请求地址。

首页当前显示 `targetTemperature`，它是设定温度；室温 `indoorTemperature` 只在详情显示。调整后应分别标“设定”和“室温”，缺失保持未知。已有绑定加载还会先在 `climate.devices` 查询一次远端状态，UI 随后又查 `climate.status`；网络失败可能连本地绑定都无法展示。后续应使绑定配置可本地恢复、状态独立更新，并明确这与旧 devices“已核验设备”契约的关系。

当前 UI 要求 power/mode/fanSpeed/targetTemperature 全齐才启用控制，跨校仅支持开关的设备可能被无关字段阻塞。跨校扩展需按设备支持项、操作所需状态分别启用，而不是所有设备强制同一套面板。

### 目标页面

未绑定时显示脚本提供的互联网绑定/红外配置入口；绑定后顶部为名称、模式和改绑操作，中间显示温度及加减，下面为开关和模式，其余能力按支持项显示。纯红外学校也能进入二级页，不能要求有可回读的 `climate.status` 才出现入口。

红外设置先检查硬件；不支持时显示“不支持红外”。支持时列出脚本提供的有限方案编号/名称，用户选择后可显式测试开/关，再保存有效方案。选择和绑定动作本身不发射。编号仅用于展示，持久配置使用稳定方案 ID、版本和来源 digest，避免方案重排后控制错设备。

网络失败或学校没有互联网方案时，用户可以主动改用已配置红外。网络命令超时、结果未知时，不能自动以红外重发。首页互联网模式显示温度及状态时间；红外模式提供明确的“开”“关”按钮，反馈“已发送指令”，不以真假 Switch 冒充实时状态。需要完整状态帧的空调协议，必须先明确初始目标值，不能直接沿用网络单字段增量假设。

### 新 ADR 应覆盖的边界

仓库尚无红外桥、权限或 SDK。现有 `climate.devices@1.0` 是只读核验设备，`climate.command@1.0` 的 applied 依赖独立状态核验，不能拿来表示“红外已发射”。可选择新 climate 版本的传输分支或独立红外契约，但应显式区分远端观测、本地目标及上次发送，兼容/拒绝旧版本的规则写清楚。

新增端口只允许受信包提供有限方案与协议编码；宿主约束频率、脉冲数、总时长、重复次数、并发及前台显式触发，保留来源/身份/取消边界。取消能阻止排队发射，已开始的物理发射不能宣称可撤回。核心不内置各学校/品牌协议，也不开放 FFI 或任意原生模块。代码库与红外码表的来源、许可需单独记录，不能从第三方遥控器应用抽取未授权资源。

Android 的 [ConsumerIrManager](https://developer.android.com/reference/android/hardware/ConsumerIrManager)提供发射器检测、载波范围与同步发射；单位为 Hz/µs，单个模式须短于 2 秒，调用应离开主线程。它不提供空调状态回读。增加 [TRANSMIT_IR](https://developer.android.com/reference/android/Manifest.permission#TRANSMIT_IR) normal 权限并将红外硬件声明为可选；系统权限不能替代脚本包授权。可以先用 Kotlin 平台桥，不必引入第三方红外库。[AOSP 实现](https://android.googlesource.com/platform/frameworks/base/+/master/core/java/android/hardware/ConsumerIrManager.java)可用于核对限制，硬件实际发射仍须单独验收。

## 群聊列表

[chat_page.dart](../../client/lib/ui/community/chat_page.dart) 第 626–642 行当前是群图标、标题、类型/ID和右箭头。[ADR-063](../adr/adr_063_conversation_names_and_order.md)已有 `lastMessageAt`，[消息归档](../../client/lib/core/messages/archive.dart)也合并服务端时间和本地消息时间。因此右侧可以直接改为最新消息时间，无需新 schema。

建议名称为主、右上为紧凑时间，今天显示时分，跨日显示简短日期，完整时间放语义说明；时间缺失留空，绝不以 fetchedAt、群资料更新时间或当前时间补造。群类型保留轻量标识，长会话 ID 移入详情/复制入口；当前没有会话预览正文、未读数契约，不为美化伪造它们。离线仍使用同一账号与来源的归档时间。布局验证长群名、320px/两倍字号、深浅色、未知时间、离线及跨时区。

## 后台同步、通知与推送

### 当前前台边界

[ADR-061](../adr/adr_061_message_history_and_storage.md)明确消息能力禁止 home/preload/后台；[manifest.dart](../../client/lib/core/scripts/manifest.dart)列出 `foregroundCommunityCapabilities`，[script_session.dart](../../client/lib/session/script_session.dart)拒绝非交互调用，ChatPage 进入后台取消请求、清页面状态，恢复时重新加载。因此后台更新需要正式扩展生命周期，不能简单加 Timer 或删除前台校验。

可以先设计用户主动启用的设备本地只读同步：按来源/账号绑定任务，有限查询、增量游标、消息 ID 去重、撤回处理，首次导入历史不逐条通知。无通知权限仍可明确展示同步状态；认证需要输入时等待用户回前台，不后台弹登录。撤销计划、退出账号、包更新与存储不可用都要停止或清理；禁止后台发送消息或重放未知结果。通知标题/正文是否展示需有隐私选择，点击通知固定来源并经过解锁/身份恢复，不把正文或凭据放进路由参数。

这条路线可复用受保护消息归档，并承接 [ADR-080](../adr/adr_080_trusted_script_extensibility.md) E5，但须单独定义消息只读后台权限与执行语义；普通前台 `interactive:false` 调用不能被视为已获后台授权。WorkManager 提供尽力执行，周期任务最短 15 分钟且可能延迟，不能承诺实时；常驻前台服务/长连接是另一种资源和系统限制更重的方案。[Android 周期工作文档](https://developer.android.com/develop/background-work/background-tasks/persistent/getting-started/define-work)

### 推送通道不等于消息来源

| 路线 | 可行性与依赖 | 当前缺口 |
|---|---|---|
| Google FCM | 自有 Firebase 项目、客户端注册、受信发送端及可用 Google 服务/网络；Android 13+ 展示通知还需用户授权 | 仓库无 Firebase 配置/接收 service；没有上游消息事件的发送授权 |
| 国产厂商推送 | 按小米、华为、OPPO、vivo、荣耀等通道配置应用身份、证书/密钥、token 与发送端 | 不是同一个 FCM SDK 的自动替代，需要分别评估准入、包签名与服务端 |
| 学校/上游合作 | 上游给出合规事件回调或直接向本应用通道发更新信号，设备再直连取数据 | 当前没有合作或应用管理权证据；需另建服务与 ADR |
| 本地同步 + 本地通知 | 消息由当前设备在授权范围内查询，通知也在设备生成 | 可先实施，但时效受系统调度、网络与登录状态限制 |

FCM 是 Google 服务，并非所有 Android 手机自带且始终可达的通用原生能力。原生 Kotlin 接收端可以接入 Flutter，但仍需要[客户端配置](https://firebase.google.com/docs/cloud-messaging/android/get-started)和[受信发送环境](https://firebase.google.com/docs/cloud-messaging/server-environment)。高优先级消息用于及时、用户可见通知，长期静默刷新可能被降级，不能用它承诺后台常驻。[FCM 优先级文档](https://firebase.google.com/docs/cloud-messaging/android-message-priority)

[超星 chat.js](../../school-scripts/xidian-chaoxing/src/chat.js)使用上游 `cx-dev/cxstudy` 环信应用；本仓只有用户会话访问路径，没有控制该应用管理台/推送证书的证据。环信第三方推送需配置相应应用的通道与证书，安装 elecon 自己的 FCM SDK 不会自动接收到学习通官方客户端推送。[环信第三方推送说明](https://docs-im.easemob.com/im/200androidclientintegration/110thirdpartypush)

“硬核联盟 FCM”未找到可直接采用的同名统一技术通道。若意指国产系统离线推送，应按上述厂商通道研究；[统一推送工作委员会](https://upc.taf.org.cn/)也不是“硬核联盟”的另一名称。通道示例见[小米推送](https://dev.mi.com/distribute/doc/details?pId=1533)、[华为 Push Kit](https://developer.huawei.com/consumer/en/hms/huawei-pushkit/)。具体 SDK 可获得性、应用准入和设备覆盖须在实际选型时重新核实。

不可为了得到事件把学生凭据交给公网轮询，或把私密聊天正文送公共中继，违反 B3。将来若有上游支持，可研究不含正文的更新信号及最小路由 token，再在设备上查询；信号不携带正文也不免除账号关联、撤销和服务端授权设计。现有 `server/src/public` 是静态分发，不能当成已具备的推送服务。

## 快捷方式与 HyperOS 4

[FeatureShortcuts.kt](../../client/android/app/src/main/kotlin/dev/nancunchild/elecon/FeatureShortcuts.kt) 第 42–45 行调用 `requestPinShortcut(shortcut, null)`，无成功回调，所有 RuntimeException 折叠为 false。[AppShortcutsController](../../client/lib/core/navigation/app_shortcuts_controller.dart)只初始化查询支持能力，返回前台未刷新；[设置页](../../client/lib/ui/shortcuts/app_shortcuts_settings.dart)只能显示“已请求/添加失败”，现有文案没有将“已请求”误报成“已固定”。

Android 官方规定：返回 true 只代表支持/受理，用户接受后才发送 resultIntent，拒绝没有回调，支持状态也可能变化。因此缺回调是可观测性缺口，**尚不是 HyperOS 4 添加失败的已证实根因**。[ShortcutManager](https://developer.android.com/reference/android/content/pm/ShortcutManager)

沿 [ADR-085](../adr/adr_085_feature_shortcuts.md)可先增加明确目标、非导出的成功回调，区分不支持、已请求、已固定、请求异常；恢复前台重新检查能力和已固定集合。超时显示“尚未确认”，不能推断拒绝；返回异常只记录净化后的分类。保留长按应用的静态快捷方式路径，不在未复现时盲加废弃广播、厂商私有接口或 root 要求。

HyperOS 4 验证应分别记录应用/桌面版本、系统支持值、受理值、成功回调、固定集合和是否已有同 ID，并检查系统桌面权限/限制。还要覆盖冷启动、正在运行、Profile 未恢复、解锁/选校、来源撤销及重复请求。实际固定与启动都通过，才能判定该系统验收完成。

## 课表桌面小部件

仓库未实现 AppWidgetProvider、receiver/XML 或原生小部件数据桥。ADR-085 的快捷方式只有页面导航，不向桌面输出私人课表，不能据此跳过新的系统展示边界设计。

建议第一片使用 Android 原生 `AppWidgetProvider + RemoteViews`，提供可调整大小的“今日课表/下一节课”，点击复用课表入口；若需要整周网格，可随后扩展尺寸布局。第一片复用前台正常查询后的[课表缓存](../../client/lib/core/scripts/data_cache.dart)，不依赖消息后台同步或新登录执行器，不必新增第三方依赖。

需先写明以下生命周期和展示规则：

- 用户配置时明确允许将哪些课表内容展示到桌面；系统 Launcher 持有已渲染内容，后续遮蔽不能承诺收回已被系统缓存或截图的内容。
- 每实例固定 Profile、学校、来源包/digest，原生只收到最小版本化展示快照，不能读取完整凭据库或执行学校协议；点击时校验绑定，不悄悄改为另一身份。
- 快照包含日期/周、时区、原始取得时间与过期状态。学校校历和课程时间沿用脚本；本地重绘不能伪装成重新查到数据。
- 切身份、退出、来源禁用/更新、Profile 删除时清除或遮蔽，处理竞态和迟到写入；M 档不因小部件而落盘。受保护快照的原生读写、解锁状态和启动时机必须在 ADR 中定义。
- 重启未解锁、没有缓存、离线或过期时有明确状态；无数据不能画成“今日无课”。日期变化/时区变化重绘已有数据，不表示刷新学校数据成功。

系统 `updatePeriodMillis` 不能小于 30 分钟；另用 WorkManager 也不能保证精确上下课唤醒。首片由前台数据更新、系统小部件更新和必要日期事件触发布局，避免为一个课表显示申请精确闹钟权限或承诺每分钟更新。[小部件更新文档](https://developer.android.com/develop/ui/views/appwidgets/advanced)

验收包含多个不同绑定实例、不同尺寸/字体、Launcher 重启、App 进程退出、午夜/跨周/时区变化、退出/撤销、无缓存/过期与点击恢复。未来选择 Glance 等依赖时再登记来源和许可证，不能把方案描述当作依赖已引入。

## 本轮证据与后续验证

### ADB 只读观测

| 项目 | 结果与限制 |
|---|---|
| 设备 | OnePlus CPH2653，Android 15 / API 35，OPlus V15.0.2；不是 HyperOS 4 |
| 默认桌面 | `com.android.launcher/.Launcher` |
| 设备上的 elecon | `0.8.1` / versionCode 12，早于当前仓库 `0.8.2+13` 快捷方式基线 |
| 快捷方式 | 对该包的系统查询未返回快捷方式条目；不能据此判定新实现失败 |
| 红外/GMS | 系统声明 consumerir 且装有 GMS；分别不证明红外发射成功或 FCM 可达 |
| 操作范围 | 仅系统属性、桌面、包版本与能力查询；未用 su、未更改设备、未导出用户业务数据 |

本轮没有 HyperOS 4 复现条件，也没有空调硬件、扫码业务、实际通话、推送收发或 Launcher 小部件验收。设备唯一标识、真实账户和原始业务数据不入库。

### 当前实现的定向回归

以下命令 **66 项通过**，涵盖现有电话/群聊/课表/教室时间轴/查询控件/快捷方式桥/空调页面，全部使用合成夹具。它证明当前基线回归通过，不证明本文新需求已实现，也不覆盖刚发现的完整跨间隙课程漏判。

```sh
bash client/tool/flutter_test.sh fvm flutter test --no-pub --reporter expanded \
  test/phone_directory_test.dart \
  test/messages/chat_page_test.dart \
  test/schedule_navigation_test.dart \
  test/classroom_timeline_test.dart \
  test/script_query_controls_test.dart \
  test/navigation/app_shortcuts_test.dart \
  test/energy_climate_sections_test.dart
```

平台研究另跑 `app_shortcuts_test.dart` 与 `shortcut_navigation_test.dart` 共 10 项通过；与上面的桥测试重叠，不相加宣称 76 项不同测试。只验证 mock 桥与导航，不能替代 Launcher 固定成功。

### 各切片关闭条件

| 切片 | 需补的主要验证 |
|---|---|
| 概要/轮播、电话、群时间、本周标记 | 有限高度、大字号/深浅色/语言、点击目标、卡片内按钮不触发父跳页、轮播生命周期与未知时间 |
| 空教室简化 | 南北完整选项、旧校区条件移除、无隐藏时段、新旧包/参数边界；楼栋覆盖与 AppFunctions 缺楼栋提示仍清晰 |
| 表单缓存 | 退出页面/重启恢复、草稿与已应用值分离、折叠项无值时按需加载、有效依赖缓存不重取、依赖改变、过期失败、跨日、身份/来源/语言失效、持久化失败与取消 |
| 日程隔断 | 不同学校分段、完整跨间隙课程、某一天午间有课、脚本休息段缺失/非法、旧输出 fallback；教室未知语义不变 |
| 网络空调/红外 | 扫码取消/拒权/非法内容、旧绑定保留、离线绑定卡、纯开关设备、无红外、有限方案升级、发送预算及未知结果禁自动转红外 |
| 后台同步/推送 | 首次历史不通知、重复/撤回/乱序、授权撤销、存储不可读、后台认证等待、Doze/强制停止/重启、合法上游事件与实际通道投递 |
| 快捷方式/小部件 | 匹配版本的 HyperOS 4 复现；固定回调和重进程导航；小部件桌面展示授权、身份绑定、失效与真实 Launcher 布局 |

建议按独立目的提交：先落既有契约内的界面与脚本筛选；再补表单缓存和脚本休息段；网络空调页面可独立先做；红外、后台消息和小部件各自完成 ADR 后实施。各片可单独回滚，脚本升级/回滚仍重新批准 digest。核心、网络、凭据与控制的人工实质审阅仍由对应实现阶段完成，本研究不替代签收或发布。
