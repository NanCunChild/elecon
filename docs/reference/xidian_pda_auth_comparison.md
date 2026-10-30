# 西电认证与 TraintimePDA 的协议对照

日期：2026-10-30。参考本地 `~/projects/traintime_pda` 的 `e780e4d0`；所列认证与网络文件无工作区修改。本文件包含源码分析、迁移方案及 0.9.0 实施记录；不代表真实账号实测通过或人工安全签收。

> 当前路线（0.12.1）：按所有者要求，默认包已移除 PDA 密码协议及自绘输入页，恢复学校原页 WebView 认证/IDS 收割，再单独执行服务签票和业务验证。PDA 源码及测试仅作后续原生界面的独立实验，以下 0.9.0 记载保留为历史对照。当前使用见[学校脚本说明](../../school-scripts/xidian/README.md)。

## 结论与现状

可以在 ADR-034/035 受信学校脚本内实现与 PDA 等价的应用层认证状态机。此前 elecon `0.8.6` 依然是学校网页执行认证、脚本轮询/采样 Cookie 的路线；它不是 PDA 的认证协议移植。继续调整网页导航无法证明与 PDA 的请求行为一致。

本次手机只读确认启用本科 `0.8.6`。CDP 观察到报错页面位于 `https://ehall.xidian.edu.cn/jwapp/sys/wdkb/*default/index.do`，固定错误特征为“系统异常 / 调用接口异常 / 正在紧急修复”；页面无密码框，UA 为 Android WebView Mobile。错误呈现于教务应用，不能单凭该页面判定 IDS 从未登录。观察时 Cookie 接口返回空结果，但浏览器关闭清理本来就会删除 Cookie，此点不能当作 Cookie 丢失的根因证据。

## PDA 的实际调用链

以下路径相对参考仓库；应对照实际调用者，而非把某个存在但未被调用的 factory 当作运行行为。

1. `lib/page/login/login_window.dart:131`：新登录清空统一 IDS CookieJar，读取原生界面账号、密码，调用 `IDSSession.login` **不传 target**。
2. `lib/repository/ids_session/ids_session.dart:190`：GET IDS login（首次无 service），从 `#pwdFromId` 表单读取 `pwdEncryptSalt`、`lt`、`execution`，检查隐藏字段存在、重复及 salt 长度。
3. 同文件 `:262`、`:398` 与 `ids_fingerprint.dart`：读取或生成稳定的 32 位大写 hex 设备指纹，访问 `/authserver/bfp/info` 注册；其持久化与脚本目前依赖官方页面自行生成指纹不同。
4. 同文件 `:75`、`:281`：按参考 AES-CBC/PKCS7 规则加密密码，提交 username/password、rememberMe、cllt、dllt、事件及表单隐藏字段；验证码由 `slider_captcha_client.dart` 独立协议处理，使用当前 IDS 会话 Cookie。该验证码文件许可为 MIT，主体认证代码为 MPL-2.0。
5. 同文件 `:311`、`:381`：识别 301/302、继续登录表单及错误响应；目标绑定的票据不在并发调用之间共享，IDS 登录与 MFA 分别串行。
6. `ids_reauth_client.dart`：准备 reAuth 页面、注册指纹、选择短信/企业微信、发送及提交验证码；**提交成功后重新 GET `login?service=...` 取得业务回跳**，保留本轮 service、isMultifactor 和信任设备语义。
7. `login_window.dart:201`：认证成功后保存账号/密码，再探测研究生身份和学期。PDA 具体采用的密码存储实现不应成为 elecon 改用明文或共享偏好的理由；elecon 继续按当前学校身份使用自己的凭据保管边界。
8. `semester_session.dart:44`：E-Hall 取学期先 `checkAndLogin(target: appShow?appId=4770397878132218)`，随后 `followIDSRedirects`，最后用原生 HTTP POST `dqxnxq.do`。它不要求 E-Hall 门户应用列表或 IDS 个人中心设置接口先成功。

`network_client.dart` 中 `NetworkClients.idsDio` 的行为是固定桌面 UA、关闭自动跳转、同一持久 CookieJar（含会话 Cookie）。`IDSSession.dio` 返回这个 idsDio；当前课表/学期/成绩类没有覆盖它。`ehallDio` 虽有额外 Referer/Accept 等头，但全仓 `lib` 没有相应调用点，不能据此认定这些头已用于上述链路或是本次错误的唯一原因。

`followIDSRedirects` 最多 30 跳，保留相对 Location 和当时的 service，每步尝试处理 MFA，之后 GET 下一跳；参考实现将后续 Location 的 scheme 改为 HTTPS。该转换是确实存在的参考行为，与 elecon 先前按要求保留原始 HTTP 跳转的实验不同。若移植，应明确验证默认/显式端口、逐跳 origin 和敏感请求体策略，不能把它变成宿主全局跳转旁路。

## 与 elecon 0.8.6 的主要差异

| 环节 | PDA | 当前学校脚本 |
|---|---|---|
| 主认证执行者 | Dio + 原生表单输入 + 协议代码 | 官方网页表单/JS + WebView |
| 首次认证入口 | login 不带 service | 先打开 E-Hall 根入口 |
| 全局会话确认 | IDS 协议响应、继续表单、MFA 状态及 CookieJar | 额外依赖门户 hasLogin、IDS 设置页及其接口 |
| UA | `Macintosh ... Chrome/130 ... XDYou/2.0.0` | Android 15、`wv`、Chrome/155 Mobile |
| 指纹/信任设备 | 稳定指纹显式注册、MFA 显式 trustDevice | 页面自身行为，WebView 开关前后清理 Storage |
| 表单字段/加密 | 明确解析并组装请求 | 不控制官方桌面/移动表单的实际请求 |
| MFA 后继续 | 重新请求绑定 service 的 login | 跟随页面导航，必要时恢复门户 |
| Cookie 来源 | 原始 Set-Cookie → 完整 domain/path/expiry 的 jar | Android 导出可能只有 name/value；未知属性保守绑定采样 URL |
| Cookie 生命周期 | 一份长期 jar；显式新登录清空 | WebView 每次清理后按允许 URL 恢复；HTTP 侧再合并 IDS/目标快照 |
| 业务验证 | 原生 HTTP POST，并沿用统一 jar | 在业务页面内 fetch，依赖此页面已正确建立业务上下文 |
| 重定向 | 原生手动处理、最多 30 跳、后续 scheme 改 HTTPS | 浏览器自动跳转；脚本 HTTP helper 上限 8 跳，沿用已验证 origin |

这些是需要逐项对照的变量，不是已确认的单一根因。固定 UA、无 service 初登、MFA 后重新签票、Cookie 路径完整性，以及网页业务上下文均值得在同一账号/网络下分别验证。

## “完整复刻”的可实现范围

应用层请求顺序、参数、AES 变换、指纹、CookieJar、MFA 与 SSO 换票可以移植为校本 JS 模块，由现有 `ctx.fetch` 和凭据 API 执行，无须把学校认证写进宿主核心。SDK 已允许读取真实响应头、手动跳转、原始 Set-Cookie、文本 body 与响应 bytes。加密和验证码图像处理尚未移植，需要可审阅实现及合成向量验证；不能将“SDK 没有单独 crypto 方法”误写成必须开放原生能力。

完整主认证会让受信脚本接触本次输入的密码和验证码。这在 ADR-034 允许的当前学校身份范围内，但与当前官方网页自行提交不同，应明确呈现。账号/密码/OTP 的交互可以复用现有浏览器 DOM 能力；若要求新增原生输入面板 SDK，则需另行审议核心/契约变化。不会默认复制 PDA 保存密码到偏好的行为。

不能承诺整个 Flutter/Dio 客户端的网络字节级一致：TLS、连接复用、DNS pinning、framing 由 elecon 已编译宿主传输承担，脚本不应取得 raw socket/FFI 或设置保留的 Host/Connection/Content-Length。PDA 的额外头 factory 还需按实际调用链区分。

当前应用中浏览器脚本的运行额度为 **20 次 `ctx.fetch`、256 次宿主调用、120 秒**；runtime API 本身默认 35 秒，由会话装配为浏览器脚本设为 120 秒。transport 的独立默认上限为 40 次实际请求，两者不能混为同一个额度。PDA 最多 30 跳、滑块六轮及邻位重试的极端路径无法原样塞进默认一次运行。应设计有界重试或分阶段执行；调整核心预算/新增交互能力时按 ADR-034 及相关决策处理，不能静默移除资源边界。本科/研究生身份已由 elecon 分开绑定，也不能机械复制 PDA 对未声明 YJSPT origin 的自动身份探测。

## 下一轮实现与验证切分

1. 先建立独立的 PDA 协议模块与合成夹具：首次无 service 登录、表单字段与 AES 向量、设备指纹注册、继续表单、滑块协议、MFA、重新签票和逐跳 Cookie 更新。将初登、换票、目标业务会话分别记录稳定阶段码。
2. 先用当前已验证 IDS 凭据对照“PDA 式 SSO 换票 → 原生 HTTP 学期 POST”，验证错误是否来自 WebView 的目标业务上下文。这个实验只覆盖换票/业务段，不能命名为已完成完整密码登录移植。
3. 补上主认证输入交互，初登不带 service；目标授权后再运行单独服务签票。目标业务验证继续保留，但不要求打开课表 HTML、门户列表或 IDS 设置页作为 PDA 模式的先决条件。
4. 验证空 CookieJar 首登、已有 IDS 静默签票、设备信任恢复、强制 MFA、过期、取消、密码错误、同名不同 path、票据单次使用和资源上限；使用真实 QuickJS 执行打包后的源模块。CI 仅用合成凭据，不访问学校。
5. 在同一设备/网络确认参考 PDA 也能登录查询，再比较真实新流程。保留 MPL/MIT 来源与许可，不把学校的认证响应原文或真实 Cookie 放入提交。

## 0.9.0 实施记录

`src/pda_login.js` 已承接 E-Hall/YJSPT 教务登录：首登无 service，解析隐藏字段、稳定 bfp、与 PDA 格式一致的 AES 密码和滑块签名、continue、短信/企业微信 MFA、成功后重新签票、统一 CookieJar 和逐跳更新，最后用原生学期 POST 验证。`pda_ui.js` 经既有 DOM SDK 提供一次性输入及 WebCrypto；本版采用 PDA 手动滑块分支，未移植自动图像识别。校园卡/图书馆保留浏览器路线。

PDA 的 HTTPS Location 规则仅用于协议客户端及 `authFlow=pda` 的会话；旧 HTTP 浏览器会话不受影响。校内业务未成功时仍保留已验证 IDS，且服务签票过程的 IDS Cookie 轮换在解析业务前持久化。设备指纹与会话均仅在当前学校身份下保存；密码/OTP 不落盘，不增加依赖、网络范围或 SDK/契约能力。

客户端对声明 browser 的脚本使用运行时早已允许的 40 次请求上限，传输层同为 40 次；120 秒、256 次调用及其他资源门保留。新增真实 QuickJS 边界回归验证第 40 次成功、第 41 次失败，即使脚本捕获异常仍不可继续。合成及浏览器输入验证不能替代 CPH2653 上的真实账号实验；生产合并仍需人工审阅。



最终实现边界：首次认证失败不持久化设备指纹为独立凭据，以免宿主把它误判为已有登录；指纹随验证后的 IDS 会话保存和复用。切入 PDA 模式时不恢复旧 WebView 业务 Cookie，目标失败仍保留旧业务存储供回退。插件 debug 原始事件日志明确关闭，避免一次性输入通过 JS handler 日志泄露，宿主固定阶段日志继续可用。
