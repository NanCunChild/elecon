# 独立 Chrome 认证监听

本工具用于手动对照 E-Hall → IDS → E-Hall 和随后独立访问 IDS 的流程。它只运行在开发机，不接入应用运行时，不修改宿主能力、学校脚本授权、网络请求或学校认证规则（ADR-034 §3/§5；红线 #3/#8）。此前入口改为学校 `/appShow` 的尝试没有完成真机验收，所有者反馈当前仍进入错误页；先收集浏览器证据再决定下一项修正。

## 实验时的源码收割流程（至 0.8.4）

此处描述 ADR-034 的受信脚本路线，不描述 V1 official bundle 的旧收割器。实现见 [login.js](../../school-scripts/xidian/src/login.js)、[session.js](../../school-scripts/xidian/src/session.js) 和 [浏览器驱动](../../client/lib/ui/scripts/script_browser_page.dart)。

1. 宿主创建独占 WebView，初始化时清理其 Cookie/Storage；脚本从当前学校的 `xidian.auth` namespace 读取已保存的 `ids` 及目标系统记录，按目标 URL 恢复适用 Cookie。
2. E-Hall 源码入口在 `0.8.4` 为学校 `/appShow`；学校网页执行密码、滑块和 MFA。脚本在 IDS 页面只尝试读取数字账号以供后续查询，不读取密码。
3. E-Hall 页面完成后，在页面内 POST 当前学期接口，要求返回正常业务 JSON 和合法学期，而非只看 URL、HTTP 200 或 Cookie 是否出现。
4. 按多个实际业务 URL 收集 E-Hall Cookie；在 IDS 的 `/authserver/login`、`/authserver/reAuthCheck/reAuthLoginView.do`、`/authserver/bfp/info` 三个 URL 收集 IDS Cookie。保留平台能导出的 domain/path/HttpOnly/Secure/SameSite/expiry；Android 缺属性时只能保守绑定采集路径。
5. 页面、数据与两组 Cookie 快照连续稳定至少 1.2 秒，最终页面及业务复查通过后，写入当前学校的 `xidian.auth/ehall` 和 `xidian.auth/ids`。等待约 100 秒，收集最多六轮；关闭、取消、超时或业务验证失败时不保存本次未完成快照，旧凭据保留，WebView 关闭清理会话。

因此，**IDS 已成功但 E-Hall 业务验证失败时，本轮新取得的 IDS Cookie 也不会保存**。代码尚未独立验证无 service 的 IDS 门户/设置页，也未将“IDS 全局认证已完成”与“E-Hall 业务已可用”拆成两个保存阶段。这是本次观测要核实的耦合，不代表已证明故障来自哪一枚 Cookie。

CAS 中全局 SSO 会话、目标服务绑定的单次 service ticket 和 E-Hall 本地会话可以同时存在。参见 [Apereo CAS 协议](https://apereo.github.io/cas/development/protocol/CAS-Protocol.html)。无 service 地进入 IDS 设置页是 IDS 会话有效的重要证据，不单凭 Cookie 名或设置页特征就断言所有下游服务均已授权。

## 启动与操作

开发机需 Node 22+、Chrome 和图形桌面。不增加依赖，默认查找 Linux Chrome/Chromium；可用 `CHROME_BIN` 指定可执行文件。

```sh
npm run trace:browser
```

工具新建 `/tmp/elecon-browser-trace-*/profile`，只启动空白页；不复用日常 profile，不自动打开、填写、提交或再次探测学校页面。Chrome 调试端口随机分配，绑定本机回环地址。

1. 在这个新窗口手动输入 `ehall.xidian.edu.cn`，记录实际使用 HTTP 还是 HTTPS。
2. 让学校跳转到 IDS，完成全部登录及额外授权，等待回到 E-Hall。无需在本步强行进入课表应用。
3. 在**同一个 profile** 单独访问 `https://ids.xidian.edu.cn/authserver`，观察最终 URL 和是否进入账户/安全设置页、是否再次要求登录。
4. 完成后告知协作者；可以先保持窗口打开以便核对。关闭该 Chrome 窗口或终端 Ctrl+C 结束监听。

## 输出与判读

启动时打印本次目录及以下两个文件。目录权限 0700，日志 0600，位于仓库外。profile 本身保留此次真实登录状态；不要将该目录作为测试夹具或提交内容。

| 文件 | 内容 |
|---|---|
| `events.jsonl` | 按 seq/time 记录请求、响应、重定向、主页面导航、Cookie 发送/拦截、Set-Cookie、Cookie 快照和页面状态 |
| `cookies.latest.json` | 最近一次变更后的 Cookie 元数据，含 HttpOnly、domain/path、Secure、SameSite、过期、来源 scheme/port 等 |

默认只记录 `ids.xidian.edu.cn` 与 `ehall.xidian.edu.cn` 的网络元数据，以及标签页主导航；不声称覆盖浏览器后台及所有跨进程 iframe 的流量。新标签页会自动接入。没有代理、证书替换、UA 覆写、禁用缓存、请求重放或 TLS 绕过。

- URL 保留 origin、净化 path、参数键和嵌套 service 路由；移除 userinfo、参数明文和 fragment，遮蔽 matrix 会话及明显动态路径段。
- Cookie 值、参数值和完整 path 只记录本次随机密钥 HMAC 指纹。相同 `valueId` 可关联 Set-Cookie、浏览器存储及实际发出的 Cookie，也可比较票据/回调参数是否变化。不同运行不可比较，密钥不落盘。
- 不保存密码、验证码、POST body、响应正文、输入框值或原始页面文本。页面探针只返回可见密码框、退出链接、设置页特征及参数错误/维护等固定布尔值，不将这些特征直接当作认证成功证明。
- `request_cookies.associated[].blockedReasons`、`response_cookies.blocked[]` 可解释未发出或未接受的 Cookie；HTTP/HTTPS、domain/path 和来源端口用于对照作用域。CDP 的 ExtraInfo 与主事件可乱序，且重定向复用 requestId；结合事件序列看整条链，不按相邻行强行配对 hop。
- `event_unavailable` 或 `snapshot_unavailable` 表示局部证据缺失；不得把没有记录某 Cookie 直接解释成服务器从未发过它。

查看一次实验时先确认：IDS 是否设置并接受了 Cookie、它是否在无 service 回访中实际发送、最终 IDS 页面是否仍要求认证；随后再对照 E-Hall Cookie、回调及其业务接口。这些结果用于定位，不自动改写 elecon 的凭据库。

## 验证

```sh
npm run test:browser-trace
npx biome check scripts/browser-trace.mjs scripts/browser-trace.test.mjs
```

合成测试覆盖嵌套 service 脱敏、同次指纹关联/跨次隔离，以及真实 headless Chrome 的连续重定向、HttpOnly Cookie、拒收 Cookie、POST body 不落日志和认证门户回访。真实浏览器测试仅请求本机合成服务；未安装 Chrome 或 Node 缺少 WebSocket 时会跳过该集成用例，不替代真实学校人工验证。

## 2026-10-30 手动实验结果

所有者在独立 profile 内从 E-Hall 根入口完成登录回跳，随后手动访问 IDS `/authserver`；未替用户输入或提交凭据。以下为元数据与固定布尔判据，不包含账号、真实 Cookie 值、票据或用户响应正文。

| 观察 | 证据与结论 |
|---|---|
| E-Hall 门户登录成功 | 根入口进入 `/new/index_xd.html`，经 `//login?service=...` 转向 IDS；登录 POST 返回 302，再由 E-Hall 接受服务票据并回到门户。门户的 `/jsonp/getUserAllUsableApp` 返回 HTTP 200 JSON，包含 `data`、布尔 `hasLogin` 和 `contextPath`；不收录应用或个人明细 |
| IDS 全局 Cookie 在登录时已经产生 | IDS 登录 POST 的 302 响应设置 `CASTGC`，host 为 IDS、path 为 `/authserver`、HttpOnly。此时尚未手动回访 IDS，不是回访之后才首次生成 |
| 无 service 回访使用了既有 IDS 会话 | `/authserver` 经 `/authserver/` 和无 service 的 `/authserver/login` 到 `/authserver/index.do`，最终进入 `/personalInfo/personCenter/index.html`。实际出网的认证请求发送了同一指纹的 `CASTGC`；前后快照中该 Cookie 未更换，无需再次提交密码 |
| IDS 个人中心正常加载 | 最终 HTTP 200；页面无可见密码框、无参数错误/维护提示，随后出现设置页特征。个人中心自身请求收到 JSON 响应；未读取或导出响应业务值 |
| 全局与下游会话同时存在 | E-Hall 回调另外设置 `/` 下的 HttpOnly `MOD_AUTH_CAS`，和 IDS 的 `CASTGC` 分属不同 host。IDS 在 `/authserver` 与 `/personalInfo` 各有自己的 `JSESSIONID`，不能按 Cookie 名合并。个人中心进入时还观察到根路径 `happyVoyage` 轮换及 `/personalInfo` 会话建立，不将其武断命名为通用令牌 |
| 作用域拒发不一定是错误 | E-Hall 请求不会发送 IDS 的 `CASTGC`；个人中心路径也不会直接发送仅限 `/authserver` 的 `CASTGC`。CDP 的 DomainMismatch / NotOnPath 与上述合法隔离一致，不据此认定 Cookie 丢失 |
| 同一教务接口在此 profile 可用 | 保留所有者的个人中心标签，在后台标签访问 elecon 使用的 `/appShow?appId=4770397878132218`，进入 `/jwapp/sys/wdkb/*default/index.do`，未见错误页。与脚本一致的学期 POST 返回 HTTP 200、业务 JSON `code=0`、合法学期结构；加/不加 XHR 头均成功。后台标签检查后已关闭 |
| 手机并非未更新到入口修正版 | 只读本地安装元数据确认指定 CPH2653 已启用本科 `0.8.4`，未读取手机凭据值或修改安装授权 |

本次证明：用户确实建立了可无 service 回访的 IDS 会话，且本次 Chrome 内的同一教务接口可用。它没有证明此前手机维护页的具体根因，也没有证明单独 `CASTGC` 就足以恢复全部 IDS/MFA 状态；应保留完整的、按 host/path 划分的相关 Cookie。

现有脚本仍把 IDS 保存绑定到 E-Hall 学期验证，独立 IDS 认证成功后遇到业务错误会丢弃本轮新会话。后续修正应分别验证、分别保存 IDS 与目标业务会话，不能仅因看见 `CASTGC` 就宣布业务可用，也不能把 E-Hall 失败视为 IDS 从未登录。浏览器正常路径首先经过门户首页，手机路径、回调、实际发出 Cookie 及页面业务上下文仍需逐项对照。

另：IDS `/authserver` 的部分服务器 Location 使用 HTTP，Chrome 随后在真正出网前内部升级为 HTTPS。复现无 service 入口时可直接从 `https://ids.xidian.edu.cn/authserver/login` 研究，不能因浏览器内部升级而直接扩大脚本的 HTTP IDS 网络授权。

## 0.8.5 实验脚本

所有者授权按上述过程实施，E-Hall 登录现在先访问门户根入口，确认门户只读响应 `hasLogin === true` 且应用列表格式有效；之后访问无 service 的 HTTPS IDS login，等待个人中心及其只读账号设置接口返回正常成功码和有效账号标识。身份标识和设置正文只在页面内用于布尔校验，不进入日志或业务输出。

IDS 按原三个认证路径及个人中心页面、账号设置接口共五个 URL 采集；保留不同 path 下的同名 Cookie。快照稳定并最终复查后立即保存当前学校的 `ids`，然后才进入 `/appShow`，以原有学期接口和稳定性判据保存 `ehall`。后续失败不覆盖旧业务记录，也不撤回已验证的 IDS 写入（ADR-035 §3）；业务阶段不再重新采集一批未经 IDS 独立验证的 Cookie 去覆盖它。

本轮仅对 E-Hall 路径使用分阶段流程（包含研究生共用教室认证），不改变其它目标入口、网络权限、SDK/包格式或标准业务输出。两校脚本均升为 `0.8.5`，更新需确认新源码 digest。计数上限和测试方式见[学校脚本说明](../../school-scripts/xidian/README.md)。

在此次仍已登录的独立 Chrome 中，使用实际 `inspectLoginPage` 函数对上述三个阶段分别检查，门户、IDS 个人中心与课表业务均返回 `ready=true`；后台标签随后关闭，原个人中心标签保留。这只验证已登录 Chrome 的页面检查和路径，不等于 Android WebView 首次登录、MFA 或最终修复已验收。

## CPH2653 移动个人中心分支（0.8.6）

手机只读注册表确认已启用 `0.8.5`，随后实际运行了门户入口。尚处于 `ehall-portal` 阶段时，WebView 已进入 `/personalInfo/personalMobile/index.html`（页面完成、无密码框、无参数错误/维护提示）；因未回到 E-Hall，脚本最终报认证超时，未进入独立 IDS 保存阶段。这不是本轮维护页复现成功，也不能只凭页面路径就补写凭据。

`0.8.6` 将这个已观测的移动路径与桌面个人中心路径一起纳入同一只读账号设置验证。门户阶段若到达经接口验证的 IDS 个人中心，先执行无 service 的 IDS 检查、稳定采样并保存，再返回 E-Hall 门户一次。必须重新通过门户 `hasLogin` 才能进入业务；重复落到 IDS 不循环重开，已独立保存的 SSO 不因门户失败被撤回。移动个人中心也加入 Cookie 采样/恢复 URL，以覆盖 Android 缺失完整 path 属性的限制。

增加移动分支成功、恢复后仍落到 IDS 的有界失败及真实 QuickJS 回归；轮询每次等待 750ms，135 次总轮询仍受 100 秒 deadline 限制。包含最多一次门户恢复的最坏宿主调用数不超过 254，权限保持原样。

## 0.10.0：取消对业务 HTML 的依赖

默认认证现从无 service 的 HTTPS IDS 官方页开始，密码/滑块/MFA 由学校页面提交，个人中心的只读账号设置验证、稳定采样及最终复查通过后即保存 IDS。之后使用收割 Cookie 单独签票及验证学期 API，不再将门户或 `wdkb` 应用 HTML 打开在 WebView 中。业务 Cookie 验证前只存在本轮内存，失败保留旧业务与已验证/轮换的 IDS；失败不会调用 PDA 密码协议。此调整覆盖本科、研究生及共用 E-Hall 教室，校园卡/图书馆保留原路径。

本轮合成回归覆盖“业务 HTML 显示接口异常、但已认证学期 API 正常”的情况；它证明客户端不再渲染该 HTML，并不证明学校服务所有接口都可用，也不将已见错误页的唯一根因归结于 UA。真实手机登录的验证状态以受信脚本计划最新条目为准。

### 本轮本科手机结果

CPH2653 确认新版源码后，本轮日志（12:24–12:25 UTC）记录 IDS 原页登录/收割成功、原生 CAS 服务交换、学期 API 验证、E-Hall 保存，最终 `generic.section ok`。所有可见浏览器导航状态均在 `https://ids.xidian.edu.cn`；没有打开旧教务 HTML 错误页；随后独立运行的成绩查询也返回 `grades.list ok`，复用了保存的业务会话。没有导出账号、票据或 Cookie 值；脱敏阶段日志在仓库外 `/tmp/elecon-webview-device.log`。研究生及其他平台不在此次真机结果范围内，代码人工安全审阅仍开放。
