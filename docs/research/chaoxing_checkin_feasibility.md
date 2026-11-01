# Chaoxing 扫码签到与 Profile 多平台登录考察

日期：2026-11-01。状态：研究，未接入学校签到。范围包括 Quasar-core 的二维码解析、登录、config、地理位置及其在 elecon 受信脚本中的适配条件。

**协议编排可以留在学校脚本内，通过普通 capability 与 `ctx.fetch` 接入。** [ADR-046](../adr/adr_046_triggered_script_requests.md) 已按所有者要求废除 action 通道；签到不再有 action 或额外宿主确认前置。登录、Cookie、二维码规则、位置表、设备参数、请求体及响应解释由脚本负责，宿主继续约束身份、网络和预算。具体协议尚未实现或在线核验。

同一 Profile 下保存教务、校园卡、Chaoxing 等多个平台会话已有存储基础；逐平台登录状态、独立退出和同平台切号尚未形成完整产品语义。它们与“为不同使用者新建 Profile”是两件事。

## 代码依据

elecon 阅读基线是 `5c57feb082ab219c1a53caa4ed855f36c0fe005a` 加本轮开始时已有工作区。Profiles 与 SDK 8 扫描实现含已暂存、未暂存及未跟踪文件，以下按实际工作区观察，不声称该提交已包含它们。约束来自 [AGENTS](../../AGENTS.md)、[当前架构](../architecture.md)、[ADR-034](../adr/adr_034_trusted_school_scripts.md)、[ADR-035](../adr/adr_035_script_credential_identity.md)、[ADR-040](../adr/adr_040_energy_and_trusted_climate.md)、[ADR-044](../adr/adr_044_local_profiles.md) 与 [ADR-045](../adr/adr_045_script_qr_scanner.md)。

参考仓库为 `/home/nancunchild/projects/Quasar-core`，提交 `96f36b38a2b01b810a2b45d66f0364183a4b7b87`，阅读时工作树干净。下表 Quasar 路径相对此根目录；函数名和行号用于定位本次快照。

| 来源 | 本次核对内容 |
|---|---|
| Quasar `chaoxing/chaoxing.go:60`，`NewChaoxingClient` | 配置解析、Cookie/密码登录、账户信息、设备参数和课程预取 |
| Quasar `chaoxing/chaoxing.go:210` 至 `AccountGetInfo` | 九组密码登录方法、Cookie 换取会话、UID/TID/FID |
| Quasar `chaoxing/chaoxing.go:934` 至 `CourseGetLocationLog` | classId 查 courseId、历史签到位置 |
| Quasar `chaoxing/chaoxing.go:1262` 至 `CheckinCheckinQrcodeURL` | 活动信息、状态、analysis、preSign、位置选择和最终提交 |
| Quasar `chaoxing/types/config.go`、`chaoxing/util/config.go`、`xidian/types/config.go`、`xidian/util/config.go` | config 字段、默认值和转换不对称 |
| Quasar `xidian/ids.go`、`chaoxing/util/deviceid.go`、`util/net/cookie.go`、`util/net/client.go` | IDS 登录链、设备字符串、Cookie 降维和网络行为 |
| Quasar `xidian/data/locations.go`、`chaoxing/util/location.go`、`chaoxing/types/location.go` | 30 条地点记录、坐标扰动、地址回退与范围单位 |
| elecon [SDK](../../contract/script-sdk/types.d.ts)、[runtime](../../client/lib/core/scripts/runtime.dart)、[HTTP transport](../../client/lib/core/scripts/http_transport.dart)、[manifest](../../client/lib/core/scripts/manifest.dart) | 宿主能力、预算、输出校验与通用请求 |
| elecon [学校会话](../../school-scripts/xidian/src/session.js)、[登录](../../school-scripts/xidian/src/login.js)、[浏览器目标](../../school-scripts/xidian/src/browser_login.js) | 当前服务白名单、凭据 namespace、Cookie 与现有登录系统 |
| elecon [ProfileController](../../client/lib/session/profile_controller.dart)、[SessionController](../../client/lib/session/session_controller.dart)、[脚本会话](../../client/lib/session/script_session.dart)、[缓存](../../client/lib/core/scripts/data_cache.dart) | 身份隔离、登录状态、退出及缓存键 |

这些源码只能证明参考实现如何工作，不能证明 Chaoxing 当前在线协议仍兼容。本轮未使用真实账号、扫描真实签到码、访问学校接口或提交签到，也未运行可能连真实服务的 Quasar 测试。

## 扫码到提交的参考链路

Quasar 的扫码入口接收字符串与可选 `Location`；它本身没有相机采集和宿主确认。主要调用顺序如下。

| 阶段 | Quasar 实际行为 | elecon 适配含义 |
|---|---|---|
| 解析二维码 | `CheckinCheckinQrcodeURL` 用 `id=(\d+).*?([0-9A-F]{32})` 取活动 ID 和 enc | 只匹配片段，未验证 scheme、host、path、参数名及重复参数，不能照搬为输入校验 |
| 查询与 analysis | 启动 `analysis → analysis2`，查询 `getAttendInfo`，读取 `getPPTActiveInfo` | 活动是否结束、是否已签到应明确区分；analysis 有服务端交互，不能仅因 GET 就认定无副作用 |
| 定位课程 | 从活动取 classId，通过内存课程表或 `getClassDetail` 得到 courseId | 二维码路径可按需查课程，不必先枚举全部课程与会议 |
| 预签到 | `newsign/preSign`，携带课程、班级、UID/TID 和活动 ID；页面含 `zsign_success` 时视为已完成 | 源码不能证明此 GET 永远只读；实现前需核验其实际效果 |
| 准备最终数据 | 再读 Renwu 活动信息及位置，填入账号、enc、设备字符串、位置等 | 平台字段及编码全部留在脚本；以活动实际类型为准，不能仅信扫码入口预设类型 |
| 提交 | POST `pptSign/stuSignajax`，解释文本结果；特定设备重复提示后再查询状态 | HTTP 成功、请求已接收和签到已完成不能混为一类；传输不确定保留 unknown |
| 验证码续提 | 响应含 validate 时，解旋转验证码并最多再提交三次 | 与现行禁自动重试边界不一致；不能直接迁移自动续提 |

脚本应先严格解析受支持的二维码格式，再向固定的已声明服务发请求，不能直接 fetch 扫描文本。需有合成用例覆盖假域名、userinfo、错误路径、重复/缺失参数、编码歧义、超大 ID、enc 大小写及过期码；具体接受格式等待有效样本确定，不把参考正则的限制误写为平台规范。活动 ID 保持字符串，避免 JSON 数字精度丢失；扫描与手动粘贴应共用脚本解析器。

参考链还有不适合直接移植的错误路径：多处解引用可能为 nil 的活动信息；analysis 正则匹配后直接索引；analysis 的完成布尔值没有被用于裁定结果，提前返回还可能留下等待发送的 goroutine。新 JS 流程应有明确的错误、取消和状态转换，不能逐句翻译 Go 并发。

## 地理位置对应表与来源语义

`xidian/data/locations.go` 有 **30 条**以中文地点名为键的纬度、经度和地址记录，包含 A/B/C 等楼宇、场馆及带“北校区”前缀的地点。`Location` 使用 `float32`，Range 注释单位为米；静态表未显式设置 Range，Go 中得到 0。表内存在共用坐标的不同地点，也没有坐标系、采集时间、精度、来源或稳定地点 ID。不能据此把楼名、空教室 buildingId 或当前设备位置视为同一实体。

**该对应表没有自动把楼名映射到扫码提交坐标。** 非测试源码中，`FormatLocation` 仅直接读取 `Locations["B楼"].Address` 作为默认地址。调用方虽可传入某条地点记录，但 Quasar-core 没有实现用户如何选择楼宇并把它传给扫码入口；不能据此推断上层应用的配置格式或默认选项。

`CheckinGetLocation` 和 `checkinDoSign` 实际采用的顺序是：

1. 查询当前活动的 Renwu 位置，纬度不等于 0 时使用。
2. 否则查课程历史位置，优先活动 ID 完全匹配的一条；没有则取字符串比较最大的活动 ID。它没有按时间排序，不能直接称为“最新实测位置”。
3. 所得纬度仍为 0 且调用方传入位置时，回退到传入位置。
4. `FormatLocation` 对经纬度分别施加约 ±0.001 度的随机偏移并四舍五入到六位；地址为空时先取 B 楼默认地址，原地址的 Go UTF-8 字节长度小于 13 才覆盖。

因此，传入坐标并非无条件覆盖活动位置，传入地址也并非总会替换原地址。JS 的字符串 `.length` 与 Go 的字节长度不同，直接翻译会改变中文地址判断。活动位置、历史位置、楼宇中心点和设备定位的语义也各不相同。

后续建议如下，均属待设计项：

- 地点表及别名匹配放在学校脚本资源中，构建时打包进同一授权源码；更新表也提升包版本并重新确认 digest。核心不维护西电楼宇和坐标。
- 地点记录需要稳定 ID、显示名、校区、坐标系、来源和版本；经纬度用度，范围用米，坐标按有限数及合法区间校验。缺失坐标用明确缺失值，不把合法的 0 纬度当作缺失哨兵。
- 展示并确认位置来源；历史记录或楼宇中心点不能标成“当前位置”。删除静默 B 楼回退和随机扰动，不以候选点证明用户到场。若产品确实需要设备实测位置，当前 SDK 没有定位 API，须单独研究通用授权与精度/时间语义。
- 活动信息虽解析 `IsRanged`，提交分支却依据 `Range == 0` 判断是否需要位置。解析失败也可能落入 0；应把“需要位置”“范围未知”和“范围为零”分别表达，无法满足要求时停止，而非降级成无位置签到。
- 首片可先选不要求定位、照片/人脸或额外验证码的扫码活动做未来验收；更复杂活动需要独立研究，不能宣称所有二维码签到已覆盖。

## config 的解析和传入

Quasar-core 的入口是 `map[string]string`，不是现成的 JSON/YAML 文件解析器。Chaoxing 的 `ConfigFromMap` 精确读取以下大小写敏感字段，忽略未知键；缺省 UA 来自常量，显式空字符串可覆盖默认值，ApiProxy 自动补尾随 `/`。账号密码和 Cookie 是构造函数的独立参数，Location 也是签到入口的独立参数，均不是这些 config 字段。

| Chaoxing 字段 | 参考实现的用途 | 学校脚本中的建议归属 |
|---|---|---|
| `UserAgent` | 请求默认头；给出 DeviceId 时重建 UA，加入 kalimdor/schild 部分 | 平台协议默认值和格式化函数；如允许覆盖须限制长度、控制字符与适用版本 |
| `DeviceId` | 未给出时取 UID 的 MD5 字符串，用于 UA | 平台账户会话中的敏感配置；是协议生成值，不是宿主硬件标识 |
| `DeviceCode` | 未给出时由 DeviceId 经 AES-ECB/Base64 等处理得到，最终提交携带 | 与平台账号和 DeviceId 一起版本化保存；不增设原生设备指纹 API |
| `FaceObjectIds` | 逗号分隔；活动要求照片时随机选一项 | 涉及个人图像引用，不能进入普通配置展示或公共资源；首片不支持该分支 |
| `ExtraClassIds` | 逗号分隔的附加班级，构造阶段获取课程 | 只有扩展课程查询时才需要；扫码单活动首片不预取全部课程 |
| `ApiProxy` | 将代理前缀拼到部分登录 URL 前，可能携带密码或 Cookie | 不迁移为可随意输入的公共代理；按 B3 保持客户端直连，任何后续中继另行裁定 |

IDS 有另一套 `Config`：UserAgent、Service、CookiesDomain、ApiProxy。默认 Service 为 `https://learning.xidian.edu.cn/cassso/xidian`，CookiesDomain 为 `https://chaoxing.com`。**IDS 的 `ConfigToMap` 导出 Service，但 `ConfigFromMap` 不读取 Service**，因此调用者通过 map 传入其它 Service 不会生效。两套 config 不能混用，也不能承诺导出再导入完全往返。学校脚本应为已支持的 SSO 服务定义固定目标，不把任意回调域名变成用户配置。

elecon 当前的参数通路是 [工作台](../../client/lib/ui/scripts/script_workbench_page.dart) 解析 JSON 对象，交给 `runTrustedScript → runtime → handler(ctx, params)`。runtime 只在此处限制 JSON 大小，并不根据能力的 params schema 做通用输入验证。`ctx.ui.requestInput` 返回瞬态字符串映射，宿主不自动拼入 params 或保存；脚本决定验证与保存方式。当前 manifest 也没有通用 config 文件或 config schema 字段，不能因本研究而添加它们。

后续配置流可在学校 JS 内组织为“协议默认值 → 当前平台账户已保存配置 → 本次允许覆盖项 → 严格校验后的配置对象”。配置应有自身版本，与包、SDK 和业务数据 schema 分开；未知字段、类型错误、空值、列表分隔/重复、迁移失败和覆盖顺序需要明确。不能把任意 map 直接变为 URL、headers 或提交体；密码不作为普通工作台 JSON 配置。

静态地点、平台端点和协议常量随源码；会话、设备字符串及个人配置留在当前 Profile/学校的授权凭据记录；二维码 enc 和短期票据默认只在当前准备/提交流程存活。现有凭据记录上限为 64 KiB，不把地点表或图片塞入凭据，也不把配置伪装成 token 来获得平台“已登录”状态。若需要独立的非密配置持久化能力，应另行设计，现有 SDK 未提供该接口。

`home.params` 会随安装包分发，业务缓存也保存实际 params；原始二维码、密码、临时票据和完整配置不应出现在这些位置。本次操作选择的账号、位置与配置版本应在用户触发时固定，提交阶段重验一致，不在流程中默默换成另一套参数。

## Chaoxing 登录与现有西电登录的关系

`NewChaoxingClient` 先尝试已有 Cookie，经 `sso.chaoxing.com/apis/login/userLogin4Uname.do` 换取会话；失败且给出密码时，按 Fanya、V1/V2、V3/V37、V21、V31、XXK、V11/XXT、V24/V34、Yunzhou 的顺序尝试九组方法。部分路径把密码放进 GET 查询，部分是表单或 AES 加密请求；构造函数随后读账号信息、生成设备参数，并并发预取课程和会议。不能把这整个构造过程当作一次廉价的登录探针。

另一条链是 Quasar `NewIdsClient`：准备 IDS 登录页、处理验证码、提交学校账号，经默认 learning SSO 服务取得 Chaoxing 域 Cookie，再供 Chaoxing 使用。它使用学校密码代请求和验证码处理；elecon 当前主认证按既定 ADR 使用可见学校原页，不能为签到恢复旧密码代理路线。

当前西电脚本的服务白名单只有 `ids/ehall/yjspt/card/library/energy`；库中虽有 `tyrzfw.chaoxing.com` 图书馆认证，也不等于已有学习通会话。主包尚未声明 learning、passport2、sso、learn、mobilelearn 等签到链所需 origins，本科 SDK 5、研究生 SDK 4 均未自动取得 scanner 权限。

后续优先考察可见学校 SSO 到 learning 的路径及已有 Cookie 的只读核验，保持“用户先登录，脚本再读取被授权的会话”。独立 Chaoxing 账号登录可作为另一条明确选择的路径；不自动拿 IDS 密码去逐域名试全部登录 API。两条路径的重定向、所需 origins、验证码/MFA 与平台支持分别核验后，只声明实际采用的精确 origins，并通过包更新重新授权。

账号信息接口 `learn.chaoxing.com/apis/user/getUserImToken` 的源码映射是：`puid → Uid`、`uid → Tid`，另有 fid、name、hxToken。失败时返回 UID/TID/FID 为字符串 `0` 的对象；移植时必须把这些情况识别为失败，不能以“有 Cookie”或非空对象判定登录有效。UID/TID 与学校学号不是同一标识，平台账号和 Profile 的关联也不能仅凭相似字段推断。IM token 在单次扫码路径未使用，不应作为签到输出返回给 UI；不为此引入 WebSocket/IM 监听。

Quasar 把 Cookie 导出成 name→value map，丢失 domain/path、有效期等信息，再用通用 Cookie 发送；elecon 应保留现有完整 Cookie 集合，按目标 URL 匹配，不将教务与 Chaoxing 的同名 Cookie 合并。新平台可使用独立的脚本会话模块/namespace，不能只把 `chaoxing` 加到当前 service 集合就认为已完成适配：现有脚本 HTTP client 也维护独立 origins 白名单。

浏览器租约是独占的，多平台登录需顺序执行并清理/恢复各自的 Cookie，不以 Profile 多条记录推导可并发多个 WebView。认证取消或失败应保留其它已验证平台会话；Cookie 轮换后的保存、调用取消与迟到结果继续沿用 ADR-035 的语义。

## 脚本可承担的范围与宿主缺口

| 范围 | 已有基础 | 后续需要 |
|---|---|---|
| 二维码和配置输入 | SDK 8 扫描、SDK 3 有界表单，取消返回 null | JS 严格解析与配置校验；30 个地点超过单个 select 的 20 项上限，应先分校区/类别，不能要求宿主识别学校地点 |
| 请求和会话 | `ctx.fetch`、完整响应头/Set-Cookie、凭据 API、可见浏览器 | JS 认证、Cookie jar、表单/JSON 编码及响应解释；无 Go、Node、FFI 或远程模块加载 |
| 协议计算 | 现有 [energy_crypto.js](../../school-scripts/xidian/src/energy_crypto.js) 有纯 JS AES-128-CBC/UTF-8 示例 | Chaoxing 所需 MD5、ECB、Base64 等在脚本内独立实现或选定许可明确的 JS 依赖；不能假定 Node crypto、浏览器 WebCrypto、URL 或 URLSearchParams 全局可用 |
| 位置 | 可显示脚本提供的候选地点 | 当前没有 GPS 能力；坐标系、来源、缺失值和地点选择需先确定 |
| 执行边界 | ADR-046 的普通 capability 与 ctx.fetch，共用身份/digest/网络/预算/取消 | 签到协议与请求步骤由脚本实现，不新增专用授权通道；具体领域输出按产品需要设计 |
| 输出 | 标准 registry/schema 与真实 QuickJS 输出验证 | 现有 `attendance.summary` 是考勤记录/汇总，不表达签到活动或提交结果；产品化时不能改变它的含义，学校协议仍可直接使用通用请求 |

网络预算也不等价：Quasar 配置请求超时 300 秒，活动查询 worker 数为 16；elecon 当前交互调用最长 120 秒，运行时 HTTP 次数上限按浏览器权限为 40/20，transport 并发上限 4、单请求 30 秒且跳转计入预算。移植应按单活动按需请求、限制分页与登录尝试，不批量搬入课程枚举、会议循环、验证码识别和跨域兜底，也不为迁移直接扩大核心预算。请求压缩声明要与 transport 实际解码能力一致，不能盲抄 Quasar 的 `Accept-Encoding`。

### 通用请求的后续实现条件

ADR-046 已废除本研究初稿沿用的 action/grant、单次 POST 宿主作用域及固定额外确认方案。签到直接使用受信脚本的普通请求；扫描、认证、活动核验、提交及状态同步可由同一脚本流程编排，核心不解析平台协议。

仍需明确 analysis/preSign 的实际效果、活动与账号绑定、二维码时效、位置来源和配置版本。远端副作用发出后无法回滚；超时、取消或不可识别响应保持未知，不在脚本中自动重发提交。签到与签退分别核验状态。原始 QR/票据和提交结果不加入首页 preload/查询缓存，切身份、更新或离页后不继续提交与应用迟到结果。

平台原始响应留在脚本内判定。扫码及原生输入值会加入已知秘密集合，任意 params 不会自动全部成为秘密；脚本须避免日志/输出回显二维码、Cookie、设备字符串及其编码值。

## 一个 Profile 内的多个平台账号

[ADR-044](../adr/adr_044_local_profiles.md) 的 Profile 表示本地使用者及独立会话/存储。当前可以在同一 Profile、同一授权学校下保存多组平台凭据：西电脚本已经以 `xidian.auth` namespace 下不同 service 键区分 IDS、教务、校园卡、图书馆和水电。SDK 2 namespace 只负责寻址，同校受信脚本仍可列出和读取其它 namespace，不能将它包装成平台权限隔离。

| 场景 | 现有能力 | 缺口或建议 |
|---|---|---|
| 同一个人登录教务与 Chaoxing | 多服务记录可共存；Profile 的存储和执行队列可复用 | 新增独立平台会话和按需登录，教务成功不代表 Chaoxing 成功 |
| Chaoxing 过期、其它平台有效 | 脚本可只刷新某个服务记录 | UI 目前没有逐平台状态；只读失败不能清掉全部已验证会话 |
| 只退出 Chaoxing | 脚本可按明确地址删除自己的平台会话 | 设置页的 `logout()` 清当前 Profile/学校全部凭据及缓存，不能拿它实现逐平台退出；本地清除与远端注销也须区分 |
| 同一 Profile 下切换两个 Chaoxing 账号 | SDK 可以存不同 key，但没有通用平台账号槽位或活动账号选择 | 首片建议每平台一个活动账号；切号必须清楚影响哪些会话、准备结果和数据缓存 |
| 两个不同使用者各自登录同校 | 现有 Profiles 隔离存储、安装授权与会话，切换撤销旧执行 | 继续使用两个 Profile，不能仅靠脚本 namespace 代替这种隔离 |
| 同一 Profile 的本科/研究生学校身份 | 当前是不同 schoolId：`xidian_undergraduate` / `xidian_postgraduate` | 即便来自同一学校，也不能跨这两个授权身份自动复制 Chaoxing 凭据；已有 namespace 共享仅在相同 schoolId 内 |

当前 `isLoggedIn` 仅判断当前学校存在非缓存凭据；保存配置、过期 Cookie 或另一个平台凭据都不足以证明所需平台已认证。设置页每行代表 Profile，展示学校/脚本和聚合保护状态；[ScriptLoginPage](../../client/lib/ui/login/script_login_page.dart) 只运行所选学校脚本的 `generic.section`，传入的可选字段为 requiredRef，没有通用平台列表/选择入口。另装同校增强包也不会自动变成第二条平台登录行，来源绑定不等于账号绑定。

建议后续以通用平台账户描述符表达平台标识、本地稳定账户 ID、脱敏标签、状态、最近核验时间及可执行的登录/退出入口；协议、登录页和成功探针由脚本决定。宿主只展示和路由标准描述符，不根据 Chaoxing、Cookie 名或学号猜状态。该描述符及操作契约需 ADR，不能先塞进 manifest。独立 Chaoxing 包与学校包内模块也需比较：前者更易独立更新，但必须沿用当前授权 schoolId，并显式约定会话寻址；不能用虚构的全局 schoolId 合并多个学校凭据。

同平台切号还影响缓存：当前 `ScriptDataCache` 的键包含学校、包/digest、能力和 params，Profile 由 store 隔离，**没有平台账号或会话代际**。若同一 Profile 内覆盖 Chaoxing 账号而这些键不变，旧账号数据可能继续展示；仅换 namespace 或保存新 Cookie 不会自动失效。需在 ADR 中确定账号维度/会话修订与失效策略，并覆盖 `latest()`、首页和待确认操作；不能只靠包版本或原始 UID 拼进 params 临时解决。

多个平台的会话寿命和账号不必相同。不要把 IDS 学号、Chaoxing UID、图书馆读者号相互覆盖；平台登录失败和退出的影响限定到明确依赖它的服务。若共用 SSO，需说明删除业务会话后是否会由剩余 IDS 会话自动重建，以及用户如何明确停止这种复用。

## 来源许可与后续切片

Quasar 根 LICENSE 是 GNU GPL v3 文本；elecon 现有西电脚本声明 MPL-2.0。按 B9，复制 Go 代码、直接翻译实现或迁入位置数据前，要先明确具体来源的许可、模块/进程及分发边界。仅改成 JS、换文件夹或打成一个脚本包不能被当作已解决隔离；可评估独立实现协议、另获授权或独立分发的方案，具体适用性仍需来源核对。本轮只记录代码观察，没有复制实现、坐标表或新增依赖。

后续可按以下顺序另行授权推进，每步先拿到对应证据再实施：

| 切片 | 先确定什么 | 预期交付与验证 |
|---|---|---|
| 登录与只读核验 | 许可路线、学校 SSO/独立账号入口、精确 origins、账户 ID 和 Cookie 作用域 | 脚本会话模块；合成失效/轮换/取消测试及真实 QuickJS 桥接；之后另做小预算、明确账号的真实只读核验 |
| 配置与地点 | config 版本/优先级、允许字段、地点来源/坐标系、缺失/范围语义 | 脚本解析器和候选地点资源；字段负例、Unicode、迁移、多地点选择和来源标识；不提交签到 |
| 平台账号模型 | 每平台一个活动账号还是多个槽位、逐平台退出、SSO 复用、缓存失效 | ADR 与迁移方案、通用账户元数据/入口；同 Profile 多平台及跨 Profile 隔离回归 |
| 签到协议与执行 | analysis/preSign 的效果、用户触发时机、票据与身份绑定、签到/签退证据 | 使用普通 capability/ctx.fetch 的学校 JS；产品所需标准数据再按 ADR 建模，不增加 action 通道 |
| 首片签到 | 明确支持的活动类型、票据时效、未支持挑战、人工审阅范围 | 合成全链与真实 QuickJS；连点/禁自动重发/过期/切号/取消/unknown 负例；另行授权一次真实签到验收 |

本研究初稿只涉及文档，后续 action 移除按 ADR-046 单独实施。具体 Chaoxing 登录和签到仍未落地；代码观察和自动检查不构成真实学校验收、平台真机或人工安全签收。
