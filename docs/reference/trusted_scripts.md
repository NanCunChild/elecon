# 受信学校脚本：使用与开发

依据 [ADR-034](../adr/adr_034_trusted_school_scripts.md) 与 [ADR-035](../adr/adr_035_script_credential_identity.md)。这条路径已接入客户端，不依赖 V2 分支、签名仪式、旧 requestGraph、Masker 或不透明句柄。旧 official bundle 作为迁移兼容路径保留，Masker 尚未全仓删除，见 [退役审计](masker_retirement_audit.md)。不把新脚本送到服务端执行。

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

三类版本各司其职：`format:elecon-script/1` 是包容器；`sdkVersion` 是宿主 API/凭据语义（2 为完整凭据地址，3 在此基础上增加原生输入）；`manifest.version` 是作者发布的脚本版本。输出的 `schemaVersion` 另属于标准数据契约，不是脚本版本。宿主识别 SDK 1/2/3，未知格式/SDK 在执行前拒绝。SDK 1 保留首版预览的同校共享键/旧 ref 隐式查找；需要输入接口的新包使用 SDK 3；纯 HTTP/浏览器 SDK 2 包仍可继续使用。迁移时同时修改 SDK、源码，并提升脚本版本后重新确认，不能只改 SDK 或同版本替换字节。脚本更新/修复/权限变化都需提升版本；卸载后重装不保留版本防回退历史，不把本地更新规则描述为全局反回滚系统。

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
