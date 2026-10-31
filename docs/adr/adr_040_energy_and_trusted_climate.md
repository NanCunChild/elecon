# ADR-040：宿舍水电查询与受信学校脚本空调控制

- **Decision**：Accepted（2026-10-31；所有者明确确认本方案并要求继续完成；规格接受不代表实现人工安全签收）
- **Landing**：契约、SDK 5 action、本科包与固定客户端卡片已实现；执行及待人工/真机验收记录见 `docs/planning/trusted_scripts.md`。
- **范围**：跨校标准数据契约、ADR-034 新受信脚本的独立 action 入口、固定客户端卡片；首个提供者仅 `school-xidian-undergraduate`。
- **依据**：ADR-001 §3/§7、ADR-004 §2、ADR-030 §3/§5、ADR-034 §2–§6、ADR-035、ADR-037、ADR-038；红线 #1/#3/#4/#5/#6/#7/#8/#9/#10。
- **人工审阅**：规格确认、实现安全审阅、真实学校/设备验收分别记录；自动测试不替代后两项。

## 1. 来源与现有缺口

只读参考本机 Traintime PDA 提交 `e780e4d01ea740c979ff5c31b9db439dbc586864`，参考工作树无修改：

| PDA 来源文件 | 已见协议/行为 | 本项目需要处理 |
|---|---|---|
| `lib/repository/ids_session/energy_session.dart` | xxcapp OAuth → ignypt；逐请求取得 timestamp/signature，AES-CBC/PKCS7 加密；NodeID → 多表 → 历史 | 独立学校会话、校园网可达性、有界查询与表具选择 |
| `lib/model/xidian_ids/energy.dart`、`lib/page/energy/water_energy_card.dart` | LastNum 是电量余量；ReadNum 是用量，StartNum/EndNum 是前/后读数 | 余量不能冒充累计 reading；保留表 ID 和前次读数 |
| `lib/repository/miscellaneous_session/aircon_session.dart` | 聚好联 HTTPS state GET / command POST；当前只有 UA/JSON headers，无 token 登录流程 | 不编造 discovery/token 接口或已经验证授权的事实 |
| `lib/model/aircon_state.dart`、`lib/page/energy/aircon_remote_page.dart` | 五种模式、五档风速、18–32℃、扫风、强力、辅热；部分操作会联动其它设置 | 有界命令；确认完整联动效果 |

现有 energy.usage 无余量、表 ID 和前次读数；没有 climate.* schema 或独立 action 入口。不能用 generic.section、登录流程、读取查询或预加载夹带控制指令。

## 2. 水电契约与校本流程

新增 `energy.meters@1.0`，返回 items：每表必填 meterId/type（水、电、unknown）/unit；可选 label/campus/dormitory/room/remaining/lastReadDate。remaining 是与 unit 同单位的剩余量，学校不提供则省略；不是金额或累计读数。lastReadDate 使用日历日 date，不补造实时抄表时刻。

`energy.usage` 及入参显式升至 1.1：输出行增加可选 meterId/previousReading/readAt；reading 仍为本次累计读数，usage 仍为该记录用量。输入增加可选 meterId，保留 from/to。registry 指向新版本，旧 1.0 输出 validator 继续保留；生成 Dart/TS、解码和字段 description 同批完成，不收紧原输出的开放字段策略。

西电多表查询要求选择当前账户发现的表，通过固定选择器或 ADR-037 select 完成，不默认取第一只表。单表单窗口调用，默认电表近一月、水表近一年，遵循日历月/年语义；显式窗口必须实际使用，预算/分页不足时失败而非悄悄截断。墙钟按 Asia/Shanghai 转 UTC；仅日历日的记录在脚本中注明确定时刻约定，缺失时间不以查询时间代替。

请求顺序：已验证 IDS → 独立 OAuth code → OauthGetUserInfo → H5UserIDLogIn → H5QueryMeterList → 所选表 GetMetRead。每个加密请求独立取得 GetSignature；AES 及签名编排留在校本 JS，不新增宿主加密 DSL。加密实现以独立向量、Node/OpenSSL 解密及真实 QuickJS 验证；若引入第三方代码，先声明来源/许可证。

水电使用当前本科身份下的独立会话键，不覆盖教务/校园卡会话；仅保存验证通过的业务会话，失败不撤销已验证 IDS。主认证继续用学校原页，不接回 PDA 密码代请求实验。

## 3. 空调标准能力

| 能力 | 入参 | 标准输出 |
|---|---|---|
| climate.devices@1.0 | 无；首次由脚本主动请求设备标识 | items：deviceId、label、温度范围、模式、风速及开关类可用控制项 |
| climate.status@1.0 | deviceId | deviceId；可选 power/mode/fanSpeed/targetTemperature/indoorTemperature/verticalSwing/turbo/auxiliaryHeat/remainingEnergy/unit/observedAt/errorCode/online |
| climate.command@1.0 | deviceId、command、对应有类型的值 | status：accepted/applied/rejected/unknown；不回显原始响应、token 或设备参数 URL |

command 限定 power/temperature/mode/fanSpeed/verticalSwing/turbo/auxiliaryHeat；宿主校验值类型、命令匹配关系、无关字段、温度和枚举边界，拒绝任意 URL/header/raw JSON 命令。西电温度为 18–32℃，协议字段映射在脚本。缺失或无效状态保持未知，不猜成关机、零温度或在线。

PDA 没有设备列表接口：devices 表示用户明确录入并经只读状态接口核验的本地绑定，不能宣称学校授权了该账号下所有设备。绑定按学校/脚本命名空间保存，UI 默认显示友好名称及掩码，不记录真实 IMEI。当前协议未要求 token；若服务要求则缺失失败，不能编造 token 或认证失败后尝试无 token 旁路。

HTTP 2xx 或 success:true 只支持 accepted；后续独立 status 核验符合目标才可显示已生效。超时、中断或响应不可识别为 unknown。没有可依赖的服务端幂等键，不自动重发。

## 4. 新源码 action 入口（SDK 5）

SDK 5 继承 SDK 4，增加可选 actions；以下仅为 manifest 增量示例：

```json
{
  "sdkVersion": 5,
  "actions": [{
    "capability": "climate.command",
    "method": "POST",
    "url": "https://gxkt.juhaolian.cn/api/device/direct/command"
  }]
}
```

最多四项，每项对应唯一已声明的已知 mutation capability；URL 为无 query/fragment/userinfo 的精确 HTTPS endpoint，其 origin 必须在 network.origins 内。SDK 1–4 拒绝 actions，旧宿主拒绝 SDK 5。command 必须声明 action，禁止列入 home。

宿主提供专用 action 入口，普通 runCapability、工作台直接运行、首页刷新及预加载不能执行 command。工作台如提供控制，也必须复用 action 确认，不能靠手写 JSON 绕过。执行顺序：

1. 前台用户操作已选设备；宿主按标准入参及最近成功取得的设备约束校验目标。
2. 固定确认面板展示学校、包、设备掩码、完整设置及联动效果；例如切模式同时变更温度/风速/强力/辅热也须显示，确认后不能另加未说明的联动。
3. 确认产生宿主内的一次性 grant，绑定学校身份、运行代际、包 digest、设备、规范化完整命令、action 声明；不交脚本构造或放入工作台 params。过期、页面离开、切校、登出、禁用、更新或取消即失效。
4. grant 消耗与请求占位原子完成，同设备执行中阻止连点。command 不能打开浏览器或输入表单，配置/认证在先前只读阶段完成。
5. command scope 的 fetch 仅允许声明 URL/method，整次最多一次网络请求并要求 redirect:error；额度在异步发送前扣除。拒绝第二次及并发请求、全部重定向，不自动重登/重试/延时重发。
6. 完成或失败后以独立只读入口同步一次 status，不复用 grant、不因同步失败重发 command。禁止乐观更新；仅反映核验回来的真实态，未知/失败明确提示操作可能未生效。

endpoint 绑定安装 digest，核心不硬编码聚好联或学校请求体。脚本将标准命令映射为校本 payload；逐项验证确认内容与实际 payload 一致。

本门只保证内建控制入口的操作语义，不声称 ADR-034 的任意受信脚本已变成只读沙箱：有网络授权的源码仍能自行请求声明站点，浏览器也有自身网络能力。用户安装信任边界不变。

新源码路线以用户安装授权替代 ADR-030 针对 V1 的 official-only/Broker/Masker 前置；确认、单请求、禁重试/重定向、未知态和禁乐观更新继续适用。不放宽旧 bundle 入口，V1 本轮不获得 command 执行。首版保持 ADR-030 Android-first 限制，其它平台只读且由宿主拒绝 command；Apple 控制另按 ADR-010/030 复评。

## 5. 包、网络和客户端

仅本科生包声明/装配新增能力；新增精确 origins 为 https://ignypt.xidian.edu.cn 和 https://gxkt.juhaolian.cn，复用现有 IDS/xxcapp。无公共代理、通配域名或 TLS 例外。本科包拟升为 0.14.0 / SDK 5，重新确认源码/身份/网络/控制能力后安装。若公共代码改变研究生包字节，须独立升补丁并重新确认，不能同版本替换；研究生不获得新增能力。

按 schema 提供固定水电卡片/详情与空调状态/控制页，采用现有 Material 3、主题及双语 l10n；按数据、屏宽和字体自适应，元信息缺失不占位，不接受学校下发 Widget tree。

水电表和用量可用 ADR-038 带原成功时间缓存，本轮默认手动查询，失败保留标注时间的旧水电结果。空调状态在进入控制页/恢复可见时各同步一次，登录/初始化仅对已绑定设备做一次非交互同步；不接入首页每分钟周期预加载，失败显示未知，不把缓存当实时态。设备标识/学号由脚本通过 ADR-037 请求，不扫描或猜测设备。

## 6. 接受后的实施及验证

1. 所有者已于 2026-10-31 明确确认本方案并要求完成；规格接受后实施 contract/、核心和包格式增量，人工实现安全审阅另行记录。
2. 同批完成 registry/schema、生成物、SDK 5 actions 解析、grant/平台门；验证所有普通/后台入口拒绝 command。
3. 迁入本科模块及客户端固定卡片，更新确定性包资产/说明，保留 MPL-2.0 来源和版权。
4. 合成 Node/真实 QuickJS 覆盖 AES 和 GET 编码、签名、会话失效、Cookie 轮换、错误响应、空表/多表选择、窗口/分页/预算、命令映射、温度/枚举边界及秘密不入日志。
5. 核心/widget 负例覆盖 grant 取消/过期/重放、连点、第二次/并发请求、重定向、超时 unknown、后台/工作台绕过、非 Android、身份/安装变化、失败后只读同步及无乐观更新；保留旧 SDK/V1/研究生回归。
6. 自动测试不访问真实学校或设备。另行完成校园网只读验收、用户明确选定设备后的控制验收及人工核心安全审阅，不能把测试通过写作真机/安全签收。

## 7. 未采用的方案

把 LastNum 填入 reading 会改变字段语义；用 generic.section 或 energy.usage 发送控制会绕过独立 action。只复制 PDA 的 POST 而不落地确认/未知态、或通过重试/乐观更新改善表面成功率，都不满足 ADR-030。旧 official-only 门不能套用到 ADR-034 的用户授权源码路径。
