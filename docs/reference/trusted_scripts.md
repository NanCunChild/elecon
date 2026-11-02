# 受信学校脚本：使用与开发

依据 [ADR-034](../adr/adr_034_trusted_school_scripts.md) 与 [ADR-035](../adr/adr_035_script_credential_identity.md)。这条路径已接入客户端，不依赖 V2 分支、签名仪式、旧 requestGraph、Masker 或不透明句柄。旧 official bundle 作为迁移兼容路径保留，Masker 尚未全仓删除，见 [退役审计](masker_retirement_audit.md)。不把新脚本送到服务端执行。

## 通用请求与按钮触发控制（ADR-046）

所有受信脚本能力统一使用普通调用与 `ctx.fetch`，不再声明 `actions` 或取得额外 grant。空调控件触发一次 `climate.command`，脚本校验参数后发送一次控制 POST；调用结束后页面查询一次 `climate.status`。操作期间禁用重复点击，不乐观改状态，失败/超时不重发。命令仍不得放入 home 缓存或预加载；空调产品页面保持 Android 范围，V1 不开放新控制。

这是开发阶段的显式迁移：当前解析器/打包器拒绝任何 `actions` 字段，包括空数组；旧已安装包只保留来源、版本及原 digest，标为需要更新且不能执行，不自动修改已授权源码或清空其它安装。西电本科升级至 0.15.0 后需重新检查并授权。各已支持 SDK 的其它接口与领域数据版本不变。

签到可以在受信脚本内使用通用请求，无 action 前置；SDK 8 只提供扫码输入。[学习通增强包](../../school-scripts/xidian-chaoxing/README.md)已提供前台登录、群/私聊历史、文本发送和受限 QR 签到。具体协议考察见[研究](../research/chaoxing_checkin_feasibility.md)。

## SDK 4 首页数据接口

[ADR-038](../adr/adr_038_script_home_cache.md) 与 [ADR-039](../adr/adr_039_script_browser_busy.md) 增加可选的声明和固定收尾提示（客户端0.4.0+7）。例如 manifest：

```json
"sdkVersion": 4,
"home": [
  {"capability": "notice.list", "ttlSeconds": 900, "preload": true},
  {"capability": "schedule.week", "ttlSeconds": 900, "params": {}, "preload": true},
  {"capability": "card.balance", "ttlSeconds": 120, "preload": true}
]
```

最多16个不同且已声明的能力，TTL为30–86400秒，params须为不超过4096字节的JSON对象。宿主自动缓存这些能力成功的标准输出及实际完成时间；参数分别缓存。预加载只跑preload项，缺认证时不弹窗口；脚本可在无参handler内自行解析当前周等默认查询。自动刷新遵守TTL，显式刷新可强制重取；失败保留原值与时间。固定首页显示缓存时间，页面重建仍可恢复；登出清除当前学校数据，更新digest后旧结果不复用。H/S/M既有选择继续适用，M档仅内存。

仅浏览器授权且SDK4的脚本获得 `await ctx.browser.setBusy(true)` / `setBusy(false)`：宿主显示固定“正在登录”遮罩，学校页面不接收交互，取消仍可用。成功依据仍由脚本验证；调用结束/错误清理遮罩，不增加关闭浏览器能力。SDK1/2/3不获得此方法；安装SDK4需相应客户端。

## 在应用中使用

1. 首次选校页或设置页打开“学校脚本”。
2. 可从文件导入 `.elecon.json`、粘贴 JSON，或加载不联网的内置示例。检查源码后点击“检查并安装”。安装前没有脚本执行。
3. 查看学校身份、版本、允许站点、可选 IP 限制及浏览器权限，确认信任。脚本可以读取/修改该学校身份的真实凭据和私密数据；它不是官方背书代码。
4. 切换到脚本学校，选择能力与参数运行。结果、已净化日志可在工作台查看；启用脚本也优先为首页同名能力提供数据。一个通知接口失败不阻断其它卡片。
5. 更新时导入同 id、同 schoolId、更高三段版本号的包并重新确认。相同版本不同内容和降级拒绝。没有静默自动更新。
6. 禁用或卸载立即使运行中的调用失效。卸载保留学校凭据；在设置中登出可删除当前学校凭据。切校、登出、更新会清除旧卡片/工作台结果。登出后主动重新运行受信脚本，可以按脚本逻辑重新登录。

首次使用凭据时复用现有 H/S/M 保护选择：硬件后端可用则使用；否则由用户选择软件档或仅内存。内存会话迁移到所选持久化后端时不会丢失。加密主密钥不进入脚本。同一应用会话的脚本调用串行，防止刷新凭据互相覆盖。首版每校只维护一个当前身份；更换同校账号请先登出，暂不提供多账号并存界面。

设置页“切换学校”和工作台选校都保留各校凭据；“登出”清除当前学校全部命名空间。设置显示的是本机已保存凭据，不代表服务器仍认可登录。过期记录仍可供脚本刷新；撤销记录不通过脚本 get/list 暴露。

统一学校包的主动登录入口沿用 `generic.section`，并声明 `browser: true`。设置页“登录/重新登录”直接执行当前选中 provider 的此入口；URL、成功判断和凭据收割由脚本中的既有浏览器逻辑决定，不再打开脚本管理页，也不从 network 第一项猜测登录地址。没有该入口时明确提示不可用；按需取数仍可自行认证。学校脚本管理用于安装/更新。

西电 `0.8.6` 的 E-Hall 登录按“门户认证 → 无 service 的 IDS 个人中心验证并保存 → 课表应用验证并保存”执行。IDS 已验证保存后，后续业务失败或取消仍保留该 IDS 记录；它不代表教务会话已成功。常规阶段日志依次包含 `xidian_login_open:ehall_portal`、`xidian_login_verified:ehall_portal`、`xidian_login_saved:ids`、`xidian_login_open:ehall`；只有最终业务验证通过才出现 `xidian_login_saved:ehall`。若手机先落到 IDS 移动个人中心，则先验证并保存 IDS，再通过 `xidian_login_resume:ehall_portal` 返回门户一次，经 `hasLogin` 验证才继续业务。两校包同为 `0.8.6`，研究生共用 E-Hall 教室入口亦覆盖；其余目标入口保持原流程。更新仍需在学校脚本页确认新源码。实验来源和分阶段成功判据见[独立 Chrome 认证监听](browser_auth_trace.md)。

脚本可在抛出的 JS Error 上设置固定 `code` 来区分可恢复失败：`input_required_card_number`、`input_required_student_id`、`authentication_required`、`authentication_timeout`、`source_response_invalid`、`network_denied`。宿主仅转发这些固定字面量，未知 code/原始 message 仍为 `adapter_failed`；既有输出/预算错误语义保留。这些旧预览错误码不再让首页推断表单或重跑；新脚本使用下文 ADR-037 的显式输入 API，输入取消/不可用等通过固定 input_* 类别报告。未知 message 仍不透传。

## 格式与打包

格式为 UTF-8 JSON，最大 1 MiB：

```json
{
  "format": "elecon-script/1",
  "manifest": {
    "sdkVersion": 2,
    "id": "school-example",
    "version": "0.2.0",
    "schoolId": "example",
    "name": "示例学校",
    "network": {"origins": ["https://campus.example.edu"]},
    "browser": false,
    "capabilities": [
      {"id": "notice.list", "schema": "elecon.notice.list", "schemaVersion": "1.1"}
    ]
  },
  "source": "export const capabilities = { async 'notice.list'(ctx, params) { return {items: []}; } };"
}
```

源码及 manifest 分开编辑，然后打包：

```bash
npm run scripts:package -w tools -- \
  --manifest adapters/_template/trusted/http/manifest.json \
  --source adapters/_template/trusted/http/index.js \
  --out /tmp/school-example.elecon.json
```

打包器不执行源码、不签名、不猜测版本，验证失败不覆盖已有输出。`version` 是严格的 `主.次.修订` 三个非负整数，禁止前导零；当前不接受 prerelease/build metadata。按整数段比较，`1.10.0 > 1.9.0`，不按字符串排序。

三类版本各司其职：`format:elecon-script/1` 是包容器；`sdkVersion` 是宿主 API/凭据语义（2 为完整凭据地址，3 在此基础上增加原生输入）；`manifest.version` 是作者发布的脚本版本。输出的 `schemaVersion` 另属于标准数据契约，不是脚本版本。宿主识别 SDK 1–12，未知格式/SDK 在执行前拒绝（各版本增量见下文）。SDK 1 保留首版预览的同校共享键/旧 ref 隐式查找；需要输入接口的新包使用 SDK 3；纯 HTTP/浏览器 SDK 2 包仍可继续使用。迁移时同时修改 SDK、源码，并提升脚本版本后重新确认，不能只改 SDK 或同版本替换字节。脚本更新/修复/权限变化都需提升版本；卸载后重装不保留版本防回退历史，不把本地更新规则描述为全局反回滚系统。

身份、权限、源码都进入 canonical SHA-256 内容身份；安装恢复时重新解析并核对 digest。文件排版变化不改变内容身份，源码文本变化会改变。规范中的三段数值版本是当前接受的 SemVer 子集，不宣称支持完整 SemVer 2.0。

[源码包 schema](../../contract/script-package.schema.json) 和 [SDK 类型](../../contract/script-sdk/types.d.ts) 是接口参考。[HTTP 模板](../../adapters/_template/trusted/http/index.js)、[浏览器模板](../../adapters/_template/trusted/browser/index.js) 仅使用虚构域名。模板不是已适配学校。首版一个包只有一个 ESM 源文件，支持内置 `elecon:html`；需要 npm 库时由作者在构建期合并为单个 ESM，不在运行时下载依赖。

这两个模板有意在 `campus.session` namespace 共享 `browser-cookies`，其值是 `{version:1,targets:[{url,cookies:[...]}]}` JSON。浏览器分别采集页面和 API URL；HTTP 按目标 origin/path 选择快照，再构造一次请求的 Cookie 头。`version:1` 属于模板内部快照，不是脚本包或 SDK 版本。

## 脚本能力

- `ctx.credentials.get(key, {namespace?})` 返回 `{id,namespace,key,value,type,scope,expiresAt,expired}` 或 `null`；过期值仍可读以便刷新。SDK 2 的 namespace 默认脚本 id；同名 `session` 在不同脚本默认分别保存。显式使用相同 namespace 可共享；它只用来寻址，不限制同校受信脚本的权限。
- SDK 2 的 `list()` 返回当前学校各 namespace 的全部可用记录，不按 key 合并。`get(r.key,{namespace:r.namespace})` 可取回相同 id；`id` 是稳定唯一描述符，脚本升级不改变它。`set/delete` 同样接受 namespace，不能指定其他学校。`@legacy` 显式访问旧登录 ref；`@preview1` 显式访问 SDK 1 学校共享键。迁移不猜测归属、不自动覆盖旧数据。
- `set(key,value,options)` 的同一完整地址表示有意更新；新记录默认 token、无期限、空范围。更新时省略的 type/scope/expiresAt 保持原值；`expiresAt:null` 清除期限，`scope:[]` 清除范围。type/scope 是脚本元数据，宿主不会因此自动注入凭据。
- set/delete 完成表示内存接受；持久化档在每次脚本结束时等待保存，业务解析/输出错误也保存已轮换凭据，不回滚远端刷新。持久化失败报 `credential_persist_failed`；内存档不承诺跨进程保存。需同时轮换的 access/refresh token 可存成一个 JSON 记录。
- `ctx.fetch(url, {method,headers,body,redirect})` 可直接发送 Cookie、Authorization 和校本字段。响应有 `status/ok/url/headers/text/json/bytes/arrayBuffer`；`headers.getSetCookie()` 保留多值。宿主不自动维护 Cookie jar；脚本或共享 JS 库管理。需要中间 Cookie 时使用 `redirect:"manual"`。
- UTF-8 / 显式 Latin-1 可直接 text/json。GBK、二进制和其它未知编码仍可拿到原始 bytes，脚本自行解码；text/json 报 `unsupported_encoding`，不静默损坏字符。
- `ctx.log(level,message)` 是受限日志；已知凭据和 URL 被净化。异常正文不作为 UI 顶层错误原因，但 handler 的 message/stack 可经同一日志通道帮助调试。不能把日志净化理解为能识别任意编码的秘密。
- 参数为 JSON 对象；输出必须是严格 JSON，并匹配声明的标准 schema/version。函数、循环引用、NaN 等稳定拒绝。首版输出最多 4 MiB；工作台预览有界，复制可取得完整结果。

## 域名与 IP 清单

```json
{
  "origins": ["https://jw.example.edu", "http://10.20.0.8:8080"],
  "ipAllow": ["10.20.0.0/16", "2001:db8:20::/48"]
}
```

`origins` 精确匹配协议、主机和端口，不支持 `*.edu`、userinfo 或路径。普通域名和 IPv4/IPv6 literal 均可声明；HTTP 必须显式列出。每个重定向目标重新校验。

`ipAllow` 是**额外限制**：存在时，每次解析所选的实际连接 IP 必须命中；空数组拒绝所有连接。省略时允许已声明域名的正常 DNS 结果，包括校内私网。原生 HTTP 将本次 DNS 结果绑定到 socket，TLS 继续验证原 hostname。白名单只约束目的地和资源，不保证受信脚本不会在获准站点上传数据或执行写操作。

## 浏览器会话与 DOM

声明 `browser:true` 后可调用 `ctx.browser.open/evaluate/text/exists/queryAll/waitFor/cookies/setCookies`。页面在用户可见路由中打开，可手工登录、完成验证码。`evaluate` 可传字符串，或函数加 JSON 参数；执行发生在页面环境，不能引用 QuickJS 外部闭包变量。

每次浏览器运行前后独占并清理应用 WebView Cookie/Storage，避免学校身份串用。需要复用登录时，以实际业务 URL 调用 `cookies(url)`，保存返回值，下次在 `open()` 前调用 `setCookies(url, cookies)`。Cookie 保留 domain/path/HttpOnly/Secure/过期/SameSite；原生平台能见度仍有限，不能承诺导出整个浏览器 Cookie 库。根路径查询可能看不到业务子路径 Cookie。多个 Cookie 以 name/domain/path 区分，不按 name 去重；不同业务 URL 的采集结果应分组保存。仅恢复允许站点、domain-match 的 Cookie，且有数量/大小限制。关闭页面立即取消本次脚本，旧回调不能再写凭据。

尤其 Android WebView 不支持 `GET_COOKIE_INFO` 时，原生插件只能导出请求 Cookie 头里的 name/value，其余属性未知。新桥接会保留平台实际提供的 SameSite 等字段，无法重建平台未提供的属性。模板对缺失 path 按采集业务路径恢复，属于保守的复用策略，不等于精确还原；跨站 SSO、HttpOnly 和到期语义仍须真机验证，需要精确会话语义时在学校脚本中明确处理。实现依据：当前解析的 `flutter_inappwebview_android 1.1.3` 的 `MyCookieManager.getCookies` 与 platform interface `Cookie` 字段约定。

例如两个脚本有意共享一个系统登录状态：

```js
const namespace = "campus.session";
await ctx.credentials.set("tokens", JSON.stringify({access, refresh}), {namespace});
const tokens = JSON.parse((await ctx.credentials.get("tokens", {namespace})).value);
// 不同系统使用不同 namespace；Cookie jar 保存完整记录，按请求 URL 生成头。
```

浏览器导航/new-window 与原生权限有明确边界：主导航限定 origin，新窗口/原生权限默认拒绝；子资源、iframe、页面请求和 service worker 使用平台浏览器机制，**不声称全部经过 ctx.fetch**。设置了 `ipAllow` 的脚本不能使用浏览器模式，宿主不会假装系统 WebView 能证明 socket pinning。

浏览器接线支持 Android/iOS/macOS；Linux/Windows 当前明确报告页面模式不可用。原生 HTTP 在 Linux 回归、Android 编译通过；Windows/iOS 构建尚未在本机验证。Android/iOS/macOS 原生登录、HttpOnly、证书、切后台等矩阵尚待真机验收。OHOS 现有 probe/pubspec 不是此功能的完整应用验收。

## 验证与迁移范围

本次回归使用合成凭据、脱敏样本、真实 QuickJS 和 loopback HTTP，不请求真实学校，不控制真实设备。现有签名 bundle 仍走原门链；只在用户明确安装启用同名能力时由新脚本优先提供。不把工具测试或 agent 审阅写成人工安全签收，也没有发布或合并到 main。

后续应优先用不同认证形态的真实学校验证接入成本，逐校将成熟能力迁入新脚本，最后随兼容窗口删除旧 runtime/DSL；不继续给旧 DSL 增加校本协议算子。

2026-10-30 已增加 [西电实际学校脚本](../../school-scripts/xidian/README.md)，对照本机 Traintime PDA 固定提交实现，分成 HTTP 数据包与可见登录包。它提供本/研教务与校园卡、借阅等现有能力；具体配置、未覆盖的字段及额外能力评估见该目录。新客户端 0.2.1 修复长拼接字符串跨 QuickJS 桥失真的问题，SDK 仍为 2；真实账号与原生设备验证尚未完成。

## SDK 3：由脚本主动请求输入

ADR-037 为所有已授权 SDK 3 脚本提供 `ctx.ui.requestInput`，不要求 browser=true；SDK 1/2 不注入此 API。旧客户端在解析 SDK 3 时拒绝。SDK 3 保留 SDK 2 的完整凭据描述符，不改变其它学校/主密钥边界。

```js
const answer = await ctx.ui.requestInput({
  title: "补充查询信息",
  message: "仅在缺少查询所需信息时调用。",
  fields: [
    { id: "studentId", label: "学号", type: "text", maxLength: 128 },
    { id: "campus", label: "校区", type: "select", required: false,
      options: [{ label: "南校区", value: "south" }, { label: "北校区", value: "north" }] }
  ]
});
if (answer === null) {
  // 用户取消；脚本决定终止或使用其它路径，不能猜测身份继续。
  return { sectionId: "query", title: "查询已取消" };
}
// 校本验证和保存属于脚本，不由宿主自动完成。
await ctx.credentials.set("studentId", answer.studentId);
```

提交返回字段 id → 字符串（可选未填字段为 ""）；取消返回 null。字段支持 text/password/select，默认 required=true、maxLength=128；maxLength 上限 4096，密码不允许初始值，select 最多 20 个唯一选项值。每张最多八字段、请求 JSON 最多 32 KiB、一次运行最多八次表单，不能并发显示；标题/标签最多 120、说明最多 1000 字符。宿主校验请求和返回，提交内容在交还 JS 前加入日志秘密集合，不自动落盘、注入参数或重跑 capability。

SDK 3 的会话总预算为已有交互上限 120 秒，表单不暂停或重置计时；网络/宿主调用预算不解除。切校、登出、更新、禁用、取消、超时及页面销毁关闭弹窗；晚到提交不能写回。安装确认会说明脚本可主动请求输入，弹窗固定标出当前安装脚本与学校。固定 input_* 错误不透传请求或用户原文；这不承诺防止受信脚本主动编码泄漏。

共享首页不再根据 card/student 错误码决定字段或自动重跑。旧 SDK 若依赖这一预览补丁，应迁移为 SDK 3 的显式表单调用，或在工作台明确提供参数。西电 SDK 3 无卡号时直接提供账户余额/流水，仅在缺失学号且查询确实需要时请求输入；官方网页登录仍承担密码、滑块和 MFA。


## SDK 6 卡片建议与同名来源

SDK 6 在 SDK 5 上增加可选静态 cards，供学校包建议宿主已实现的卡片类型与有限形式；用户保存的布局优先。旧 SDK 不必升级即可使用首页长按编辑、排序和尺寸调整，cards 也不替代 home 查询缓存策略。同名能力可在工作台明确选择来源，主包不需为增强包写适配逻辑。格式、实际操作与边界见[卡片与同名覆盖](card_layout_and_overrides.md)和 [ADR-043](../adr/adr_043_card_layout_and_overrides.md)。

## SDK 7 首页命名

SDK 7 可选静态 `manifest.homeTitle` 为学校首页命名，与安装包 `name` 分开。最多 80 个 Unicode 字符、单行纯文本，缺省回退学校名；安装时展示并绑定授权 digest。SDK 7 继承现有 home/cards 与执行权限，旧宿主拒绝未知 SDK。更新既有包须提升 version 并重新确认，不能仅修改本地已授权字节。声明示例、标题来源与实际数据更新时间见[首页标题](card_layout_and_overrides.md#首页标题)。

## SDK 8 二维码扫描与本地 Profiles

[ADR-045](../adr/adr_045_script_qr_scanner.md)：包提升 `sdkVersion: 8` 并声明 `scanner: true`，重新安装/更新确认后可调用 `await ctx.ui.scanQRCode()`。成功返回 `{text, format: "qrCode"}`，取消返回 `null`。只允许前台交互执行，首片支持 Android/iOS；后台返回 `scanner_unavailable`。每次执行最多三次顺序扫描，结果最多 4096 UTF-8 字节；错误通过 `error.code` 给出固定 `scanner_*` 或 `invocation_cancelled`，不含二维码内容。SDK 8 继承原有 homeTitle/home/cards，现有学校包不会自动升级。

```js
const qr = await ctx.ui.scanQRCode();
if (qr === null) return { items: [] }; // 用户取消，由脚本决定结束当前流程
// 按学校协议解析 qr.text；扫描不会打开 URL、保存数据或自动提交签到。
```

扫码不代表已签到；真实提交使用脚本通用请求，后续产品化再明确领域数据及用户交互；当前没有签到 capability。未知结果不能自动重试。扫描文本由宿主加入日志遮蔽集合，脚本作者也应避免输出临时票据。

[ADR-044](../adr/adr_044_local_profiles.md)：设置的账户区域每个 Profile 显示一行，点击后可添加用户、激活、登录或重新选脚本。新 Profile 重新选择并授权安装，凭据、安装授权/来源和缓存独立；切换保留原登录并取消原调用，退出只影响当前 Profile。旧数据原位迁为 Profile 1。保护图标及 tooltip 来自实际凭据 metadata，Profile 名称不包含推断的用户身份。首页学校布局仍是非密共享展示偏好。

脚本保护的事实、选项与限制见[混淆/加密与 QuickJS 研究](../research/script_protection_feasibility.md)；当前没有加密包或 VMP 接口。

## 功能查看与校园卡二维码（ADR-047）

首页图标和摘要打开原生功能页面，全宽卡片提供“查看”入口；只有编辑模式调整卡片大小。课表页面为七日时段网格，首页全宽为今天时间线，日期不确定时不假报今天课程。

学校可分别提供 `card.balance`、`card.transactions`、`card.qr`。二维码学校无需提供虚构余额或消费记录，`cards.type=card` 接受任一能力。`card.qr` 1.0 返回 PNG 的 `imageBase64`、`issuedAt`、`expiresAt` 和可选 `purpose`。图片不含 data URI 前缀、不允许远端 URL，最大 256 KiB、显示尺寸最大 2048×2048；客户端最多显示 60 秒，页面后台/退出/身份变化后清除，刷新由用户触发。禁止加入 `home`，否则安装校验拒绝。此接口不执行支付提交。

空教室进入后自动准备教学楼并显示搜索，选定代码后不重复请求楼目录。静态目录须由学校脚本维护真实楼名/代码；当前西电仓库仍缺此名单，本轮保留首次发现兼容路径，未宣称完全离线目录已完成。

## SDK 9 服务账号与前台消息

[ADR-052](../adr/adr_052_community_accounts_and_chaoxing.md) 新增可选 `websocketOrigins: ["wss://service.example"]`。最多 8 个精确 origin，安装页单独显示；HTTP/browser origins 不授予 WebSocket。SDK 9 可用 `ctx.websocket.open(url)`、`send(Uint8Array)`、`receive(timeoutMs)`、`close()`。每运行一次连接、最长 30 秒，握手 10 秒，单帧/消息 64 KiB，收发各 1 MiB/128 帧；接收等待 1–5000ms（默认 1000），超时 null，关闭/错误抛出固定错误。禁止跳转、压缩、任意 headers 和自动重连；协议、鉴权 token 和 ACK 由脚本处理。原应用进后台、切校/身份/来源、更新和取消销毁通道。

`forum.session` / `messages.session` 的 `operation=status|login|logout` 表示核验、显式登录、本地退出，不等于远端注销。`messages.list` 只返回明确账号下的前台消息窗口（不是完整历史或未读数）；`attendance.checkin` 在当前调用中取得 QR 输入并返回 confirmed/already/ended/unsupported/cancelled/rejected/unknown。四能力禁止 home/cache/preload 及后台调用。

基本包 0.18.1 提供睿思账号；SDK 9 学习通包作为第三方社区包，由用户自行获取后通过通用文件入口导入，客户端不内置产物或推荐提示。论坛 Tab 要求当前可执行 `forum.session`，消息 Tab 优先使用 `messages.conversations`，旧包回退 `messages.list`；无支持则隐藏。登录/消息/签到绑定同一选中包，不自动借用其他包的账号 handler。每平台一个当前会话，先本地退出再换号；当前 Profile/学校仍是授权边界，namespace 不是权限沙箱。

## 待完善信息与缓存优先桌面（ADR-059/060）

能力缺少尚未填写的业务资料时可以抛出带 `code: "configuration_required"` 的 Error。不要把网络、认证、解析失败编码为缺配。宿主把状态绑定当前身份、来源 digest、能力与查询参数，自动及整体刷新跳过已知缺配项；显式的配置请求成功后恢复。空调使用明确 `configure:true` 才请求设备信息，不会因打开桌面要求填写设备号。

学校脚本更新必须重新确认 digest。新的错误码在不支持的旧客户端会回退为普通失败，不改变原输出 schema。SDK 10 的设备输入见对应 ADR 和 `contract/script-sdk/` 声明；仅声明已实现且需要的权限。

启动先读取当前身份下的缓存和学校布局，随后后台刷新。已有缓存的过期标记和取得时间不被刷新失败或读取动作改写；未预加载的通知仍可在首屏后及手动刷新时查询。其他 Profile 在切换前显示「切换后查看」，不推断未登录。


## 会话历史与本机存储

[ADR-061](../adr/adr_061_message_history_and_storage.md) 的 `messages.conversations/history/send` 1.0 同样仅前台、禁止 home/preload，不新增 SDK 权限。先调用同包 `messages.session` 核验账号，后续请求显式传入 accountId；历史和发送还需 conversationId/conversationKind（group/direct）。历史返回稳定消息 ID、纯文本摘要、时间/方向、hasMore/nextCursor 和 recalledIds；游标不跨会话或账号复用。发送必须由按钮触发，提供 clientId 和 text；sent 必须有匹配服务器 messageId，unknown 不得自动重发。

本机 SQLite 由核心管理，脚本不读取或写入数据库。已加载数据按当前 Profile、学校、包 digest、服务账号及会话类型隔离，使用原 H/S/M 保护；退出/认证失效/撤销来源清除，迟到结果不能恢复。最多 4 MiB/2000 条消息/500 会话，最近取得时间保留 30 天；M 档不跨重启保留。作业、课程、任务、活动与附件只显示摘要，没有跳转/操作契约。`messages.list` 的旧窗口行为保持不变。

## APPTunnel 网络选择（ADR-062）

在设置的「应用内 VPN」为当前 Profile/学校选择直连或 Hermes/aTrust。Hermes 首片 Android 原生库随构建固定，不安装系统 VPN，也不加载脚本提供的动态库。填写 HTTPS 网关 origin 和可选的可信节点证书 SHA256，在网关原页面完成登录后点击检查；核心核验并按当前 H/S/M 档保存会话，界面不获得 Cookie/SID/签名密钥。未编入、未登录、资源不匹配、DNS/证书失败都停止请求，不自动回落直连。

选择作用于受信学校脚本的 HTTP/WSS，授权 origin/IP、目标 TLS 与请求预算继续执行；没有脚本网络新字段。一般学校网页登录先在直连完成，再启用 Hermes；普通学校 WebView 暂未接入隧道，隧道模式明确拒绝其直连。V1 同样不支持；已有不可取消的 V1 操作结束前暂不能更改选择。网关认证仍是核心受控浏览器，支持同校已批准的 HTTPS 认证 origin。清除网关会话只清除此学校的 Hermes 材料，保留学校业务凭据及明确的路由选择；需手动选择直连才恢复直连。

## SDK 10 前台照片与当前位置

[ADR-058](../adr/adr_058_foreground_device_inputs.md) 增加 `manifest.deviceInputs: ["camera", "image", "location"]`，按实际需求声明；安装/更新页显示，旧 SDK 1–9 不接受。扫码仍由独立 `scanner:true` 授权。学校脚本升 SDK/包版本并重新确认后，可主动调用：

```js
const photo = await ctx.ui.capturePhoto(); // 拍照；取消 null
const selected = await ctx.ui.pickImage(); // 用户选一张图片；取消 null
const position = await ctx.ui.getCurrentPosition(); // 当前 WGS84；取消 null
```

图片返回 `{bytes:Uint8Array,mimeType:"image/png",width,height}`，去原文件名/路径/EXIF、最长边1280px、最多512KiB。图片是普通输入，不是人脸活体或身份已验证的结果。当前位置包含 latitude/longitude（十进制度）、accuracyMeters（米）、capturedAt（UTC RFC3339）、coordinateSystem=`wgs84`，不使用历史或手填坐标冒充设备实测。

三种输入都只在前台允许，与扫码/表单互斥，每次运行最多四次。SDK10 `ctx.fetch` 可接受最多1MiB的 Uint8Array body，用于脚本组装 multipart；无自动上传或重试，旧 string body不变。使用固定 `device_input_*` 和 `invocation_cancelled` 错误码；未满足服务配置使用 [ADR-059](../adr/adr_059_capability_configuration_state.md) 的 `configuration_required`，不伪造空结果。

完整 [签到模板](../../adapters/_template/trusted/attendance/README.md) 演示按钮、QR、拍照、选取本人图片、定位和一次二进制提交后独立核验。模板默认未配置，不访问 `.invalid` 示例域名。真实服务的活动要求、认证、坐标转换和人脸验证仍由学校适配决定；不能仅因SDK有输入API就宣称学习通照片/人脸签到已实现。


## SDK 11：账号需求与设置入口

[ADR-064](../adr/adr_064_script_accounts_and_tunnel_credentials.md) 要求 SDK 11 manifest 必填 `accounts`，空数组明确无需账号。SDK 1–10 的省略只表示尚未声明。当前学校各已安装脚本的账号说明在「设置 → 脚本所需账号」查看，安装确认也展示声明；此读取不运行脚本、不检查远端登录状态。

```json
"accounts": [{
  "id": "campus",
  "name": "学校统一认证账号",
  "instructions": "使用学校官方页面登录；遇到验证码或多因素验证时按页面完成。",
  "capabilities": ["schedule.week", "grades.list"],
  "login": {"capability": "generic.section"}
}]
```

每包最多 16 项，ID 唯一；依赖能力及登录能力须由同包声明。name 最多160、instructions最多2048个 UTF-16 代码单元，单行纯文本；登录参数是最多4KiB UTF-8 JSON对象。`login` 可省略，此时必须在说明中交代外部或共享登录的做法，页面不显示登录按钮。需要主动调用的认证绑定现有能力（如 `forum.session`/`messages.session` 的 `operation:login`），不下发 Widget 或宿主协议。

登录按钮固定到用户查看的包及 digest，在前台调用，离页/切身份/撤销取消；不跟随 provider 覆盖去另一个包。账号名不是凭据 namespace 或权限，声明不会限制或扩大同校受信脚本的现有凭据可见性。升 SDK/修改声明需提升包版本、重新确认；不改写旧安装字节。

## APPTunnel 账号配置

「设置 → APPTunnel」可保存 Hermes/aTrust 的 HTTPS 网关、可选节点证书 SHA256、账号、密码和可选认证域。账号与会话分别保存在当前 Profile/学校的 H/S/M 后端，普通脚本不可读；界面不回显已保存密码。空密码仅保留同一网关/用户名/认证域的原密码，修改身份需重新输入。保存账号会清除本地旧会话并撤销旧路由，不等于已登录。

点击「使用已保存账号登录」只尝试一次密码认证；空认证域仅接受网关唯一的密码域。验证码、MFA或需要指定认证域时显示需要交互，用户可核对认证域或主动选择官方网页登录。清除同时删除账号和会话；认证及保存可取消，失败不自动重试或回落直连。普通学校 WebView 尚不能经隧道运行，仍按 ADR-062 拒绝直连；真网关/移动端验收单独完成。

## SDK 12：多来源卡片、账号状态与 APPTunnel（ADR-066）

显式 `cards` 实例绑定声明包与批准 digest，同类型可重复，但包内 id 必须唯一。例如超星增强包：

```json
"cards": [{"id":"learning-notices","type":"notice","title":"学习通知","defaultVariant":"regular"}]
```

模板要求的能力必须同包声明。客户端保存每个实例的布局、尺寸和显隐；刷新、缓存、详情与重新登录保留该来源，不修改全局同名能力覆盖。无显式 id 的旧声明保持默认 provider 语义。完整卡片的内容高度不再向整数格高度补白，小卡片仍保持固定几何尺寸。

账号可声明 `status: {"capability":"account.session","params":{"account":"<账号id>","operation":"status"}}`，同时声明 `account.session` 1.0。账号页前台检查只允许无交互查询；后台执行会被拒绝，返回 `status` 为 authenticated/signedOut/expired/unknown，以及可选 `accountId/accountLabel/checkedAt`。网络错误必须 unknown；只有源站失效证据才能 expired。普通账号登录须由脚本在 login 返回 authenticated，返回账号页后再查询 status；APPTunnel 在凭据更新后的新代际查询 status 再判定成功。保存凭据本身不算认证。

内置 Hermes/aTrust 由宿主维护密码和会话。声明 `appTunnels: ["hermes-atrust"]` 的 SDK 12 包可以调用 `ctx.appTunnel.status("hermes-atrust")`、`ctx.appTunnel.login("hermes-atrust")` 并建模为脚本账号；登录仅允许用户主动账号登录入口，通过固定 APPTunnel 页面完成。状态只返回账号语义，管理端口不暴露密码/会话、不替脚本开放直连、不自动选择路由。认证发布会撤销旧脚本执行，登录页等待管理页返回后以新代际重查同包状态；仅打开后返回属于取消，即使旧会话仍有效也不报告新登录成功。

消息新版本为 `messages.list` 1.1、`messages.history` 1.1、`messages.conversations` 1.2。活动/指令仅标识与展示；群历史的 `sendPermission` 缺失或 unknown 不允许发送，muted 明确提示禁言，停用群以 `sendPermissionReason: group_disabled` 保留原因。页面依据当前在线历史结果授权，离线快照不授权；脚本在实际发送前复核。旧 schema 快照独立保留。

西电基础包 0.22.0 与超星增强包 0.5.1 采用 SDK 12，更新需要重新检查安装。超星 HTTP 学习通知独立于环信消息：通过官方 PC 前端 `POST /pc/notice/getNoticeList` 读取当前上海年份的收件通知，列表正文供详情，不标已读、不发送；Quasar-core 用于确认独立 HTTP 模块，其 `myNotices_v2` 在实站拒绝来源 IP。实际字段和分页依据官方前端及真机结构验证，未复制 Quasar 的 GPL 实现。
