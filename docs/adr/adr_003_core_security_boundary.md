# ADR-003：可信核心、QuickJS 与宿主网络安全边界

- **状态**：已接受（Accepted）
- **日期**：2026-08-11
- **依赖**：[ADR-000](./adr_000_abstract.md)、[ADR-001](./adr_001_project_shape.md)、[ADR-002](./adr_002_execution_trust.md)
- **后继细化**：[ADR-004](./adr_004_credential_store.md)、[ADR-005](./adr_005_adapter_v2.md)、[ADR-007](./adr_007_transport.md)、[ADR-011](./adr_011_capability_response_cache.md)

## 1. 背景

V1 已有背景 QuickJS、宿主 fetch、redirect、cookie、资源预算和输出 schema 校验，但其网络语义服务于“adapter 看不到凭证”：原始 URL 字符串 wildcard、少量请求头 allowlist、隐藏 `Location`/`Set-Cookie`、Broker 自动凭证注入与收割。V2 的受信 adapter 自行处理认证流程，这些限制不能原样继承。

本 ADR 固定客户端唯一生产 runtime 的不可绕过边界。Manifest V2 的字段和 SDK 类型由 ADR-005 表达；Credential Store 的精确事务 API 由 ADR-004 表达；transport 的平台接线由 ADR-007 表达。

## 2. 可信核心范围

adapter 使用普通异步 JavaScript，在背景 QuickJS isolate 中执行。可信核心只保留：

- ADR-002 定义的执行 grant 准入和失效；
- QuickJS isolate、module resolver 和 host API；
- canonical URL、manifest 网络规则与唯一 transport 出口；
- 请求、响应、资源预算、取消和副作用提交屏障；
- 参数与标准输出 schema 校验；
- 平台 secure storage、WebView 和 official transport 的受控接线。

adapter 不获得 Node/Dart 模块、文件系统、进程、raw socket、WebView controller、原生 FFI、动态原生模块、transport 选择权或 UI 线程同步执行能力。host function 必须在 module evaluate 前一次性安装，运行中不得扩权。

## 3. QuickJS 生命周期与语言能力

每个 active installation 的 exact digest、trust epoch 和 App runtime generation 对应一个长驻 QuickJS isolate。同一 isolate 的 capability invocation 进入串行队列，不并发执行；不同 adapter 可以并行。

正常 invocation 完成后保留 module instance、JS globals 和显式内存状态。以下变化必须销毁旧 isolate，不得把状态迁移到新 grant：

- bundle digest、active source 或 trust epoch 变化；
- disable、revoke trust、delete 或 ADR-002 定义的执行面重建；
- App/host runtime generation 变化；
- invocation timeout、OOM、取消、引擎中断或 fatal host error。

fatal invocation 必须回滚其宿主副作用、取消 transport 并销毁整个 isolate。队列中的后续调用只有在重新校验 active digest、grant 和 epoch 后，才可由冷启动的新 isolate 执行；旧 globals、Promise jobs、timer 和 host callback 不得复活。

`eval` 和 `Function` 保留普通 JavaScript 语义。official 审核策略可以拒绝或升级含动态代码的 bundle，但 official 与 local runtime 不因此分叉。static/dynamic import 只能解析 canonical bundle digest 覆盖的 module map或官方随 App 固定的宿主模块；remote import 永久拒绝。

Manifest 继续声明最低兼容 Elecon App 版本，用于宿主 API、SDK 和整体功能门；QuickJS bytecode 另按 ADR-005 的精确 Elecon QuickJS ABI ID 兼容，不得用 App version 代替。App release ledger 固定实际引擎源码、补丁、编译配置和所支持 ABI ID 集合。

## 4. 结构化网络规则

Manifest V2 的每条网络规则是结构化对象，至少包含：

- `scheme`；
- exact `host`；
- exact `port`；
- canonical path segment prefix；
- 非空、去重且大写的 `methods`。

规则不支持 host wildcard、正则或字符串 URL template。多个 origin 必须逐条声明。query 和 fragment 不产生额外目标权限；fragment 不发送到 transport。manifest validator 与客户端可共享纯规则向量，但客户端实现是唯一生产裁定权威。

生产网络只支持 HTTPS 和显式 HTTP。HTTPS 是默认；每个 HTTP origin 必须在 manifest 中逐条声明，local 安装界面显著展示明文风险，official 审核将其作为升级项。`file:`、`data:`、自定义 scheme 及其他协议永久拒绝，不能借 Fetch 绕过文件、native 或宿主网络边界。

所有 adapter 请求和每个 redirect hop 必须先 canonicalize，再逐字段匹配规则。未命中在 DNS 和 transport 前拒绝。manifest 声明是 fail-closed 上限，不是用户逐项授权，也不是内容 DLP。

## 5. URL canonicalization profile

policy 与 transport 必须消费同一个不可变 canonical URL 结果，禁止“检查原始字符串、transport 再次解释”。首版 profile 至少固定：

1. 只接受绝对 URL；
2. scheme 和 host 使用 ASCII lowercase；
3. 禁止 userinfo；fragment 在 policy 前移除且永不发送；
4. 域名按固定 IDNA/UTS-46 profile 转为 A-label，拒绝转换错误、空标签和歧义尾点；
5. IPv4 只接受 canonical dotted-decimal，拒绝十六进制、八进制和短写；
6. IPv6 解析为 128-bit canonical value，禁止 zone ID；
7. 默认端口归一，非默认端口必须由 manifest 精确声明；
8. 拒绝非法 `%`，decode unreserved，percent hex 统一大写；
9. 删除 dot segments，拒绝编码后产生 `/`、`\\` 或 dot-segment 的二次解释歧义；
10. 空 path 归一为 `/`，path prefix 按 segment boundary 匹配；
11. transport 使用该 canonical scheme/host/port/path/query，不重新解析 adapter 原始输入。

精确字符表、IDNA profile、path/query serialization 和测试向量由 ADR-005 固定为 contract 资产。canonicalization 失败一律是稳定 policy error。

## 6. DNS 与地址策略

exact manifest host 命中后，宿主不按解析结果的地址空间拒绝连接。获准域名和获准 literal IP 可以访问 public、RFC1918、ULA、CGNAT、loopback、link-local、metadata、multicast、unspecified 或其他地址；mixed public/private DNS 结果也不因分类而整体拒绝。

宿主仍必须保证检查与连接的一致性：

- 每个请求和 redirect hop 重新解析；
- 将本次选择的解析地址 pin 到实际连接；
- 连接重试只能使用本次已解析的结果；
- TLS SNI、证书验证和 HTTP authority 继续使用 canonical hostname；
- system VPN 与 official transport 不得把请求改送到本次解析集合之外的目标，除非 ADR-007 明确定义等价的目标绑定证明。

该策略主动接受 DNS rebinding 后访问用户本机、LAN 和 metadata endpoint 的风险。安全边界是“只能访问 manifest 精确声明的 host”，不是“获准 host 只能落在安全地址空间”。审核和用户展示不得声称宿主阻止 LAN、本机或 metadata 探测。

## 7. Web-compatible Fetch API

SDK 提供 Web-compatible 的 `fetch`、`Request`、`Response`、`Headers`、`AbortController`、body 与 stream API。目标是常用 Web API surface 和稳定可测行为，不模拟浏览器 CORS、preflight、service worker、HTTP cache、页面 referrer policy 或浏览器安全上下文。

Elecon host policy 始终高于 Web API 参数：

- URL 与 method 必须命中 manifest；
- body、stream、header、redirect、时间和字节受本 ADR 预算限制；
- host error 使用版本化稳定 code，不向 JS 暴露未净化 URL、header、cookie 或 body；
- stream 背压和取消必须传到 transport，不能先无界缓冲再交给 QuickJS；
- `AbortSignal` 只能进一步收紧 invocation 生命周期，不能延长宿主 deadline。

SDK 可以使用 Web 同名类型，但必须文档化与浏览器 Fetch 的差异，并由 contract tests 固定；不得笼统宣称完整 Fetch Standard 合规。

## 8. Header 边界

adapter 可以设置全部应用层 header，包括 `Authorization`、`Cookie`、`Origin`、`Referer` 和校本自定义头。宿主只保留协议路由、连接与 framing 完整性所必需的 header，包括：

- `Host` / HTTP2 `:authority`；
- `Content-Length`、`Transfer-Encoding`；
- `Connection` 及其声明的 hop-by-hop fields；
- `Proxy-*`、`Upgrade`、`TE`、`Trailer`、`Expect`；
- 平台 transport 为安全连接必须独占的其他等价字段。

保留字段由宿主计算或拒绝，不能静默采用 adapter 值。所有 header name/value 必须执行语法、CRLF、单值、数量和总字节限制。

跨 origin 自动 redirect 不重放 `Authorization`、`Cookie`、`Origin`、`Referer` 或其他被 SDK 标记为 sensitive 的 header。301/302/303 按 Web-compatible 规则改写为 GET 并丢弃 body；307/308 同 origin 可保留 method/body，跨 origin 且存在 body 时自动 follow 必须失败并要求 adapter 使用 manual redirect 后显式发起下一次、重新受 policy 约束的 fetch。

## 9. Redirect

Fetch 支持 `redirect: follow | manual | error`，默认 `follow`：

- `follow` 由宿主逐跳 canonicalize、解析、匹配 manifest 并计入预算；
- `manual` 向 adapter 返回 3xx、canonical response URL 和有界 `Location`；adapter 发起下一请求时重新经过完整网络门；
- `error` 遇任何 redirect 稳定失败；
- transport 永远不得自动跟随 redirect；
- 超跳、非法 `Location`、规则不匹配或预算不足均整次 fetch 失败，不交付被阻断 hop 的 response body。

## 10. Cookie

`ctx.fetch` 不提供 host-managed cookie jar。宿主不解析、不自动发送、不更新也不持久化 cookie；V1 自动 credential injection、cookie harvest、`setEphemeralCookie` 和 per-execution jar 全部随迁移删除。

Fetch 采用 Node/爬虫式 server-side 语义：response headers 向 adapter 暴露有序、多值 `Set-Cookie`，至少提供 Web-compatible `Headers` 加 `getSetCookie()` 或等价 raw multi-value API。adapter 自行解析 cookie attributes、自行决定 domain/path/expiry 语义、自行构造后续请求的 `Cookie` header，并通过 ADR-004 的 Credential Store API 显式持久化所需 session。

`redirect: follow` 不保存或重放中间响应的 `Set-Cookie`。需要中间 cookie 的认证流程必须使用 `redirect: manual`，读取该 hop 的 `Set-Cookie` 后显式发起下一次、重新受 policy 约束的 fetch。核心不提供 cookie parser、PSL 或隐式临时 cookie 状态。

## 11. 资源预算

Manifest 可以请求预算，宿主提供统一默认值和不可由用户确认绕过的绝对硬上限。未声明使用默认值；超过硬上限的 manifest 在安装/加载时拒绝。全平台 contract 数值一致，平台资源不足可以稳定失败但不能静默提高上限。

| 预算 | 默认值 | 绝对硬上限 |
|---|---:|---:|
| QuickJS heap | 64 MiB | 128 MiB |
| invocation CPU | 5 s | 15 s |
| invocation wall | 35 s | 120 s |
| 单请求 wall | 10 s | 30 s |
| invocation 内 concurrent fetch | 4 | 8 |
| transport hops | 20 | 40 |
| 单请求 body | 1 MiB | 8 MiB |
| 单响应 body | 8 MiB | 32 MiB |
| invocation aggregate response | 16 MiB | 64 MiB |
| serialized output | 4 MiB | 16 MiB |
| adapter log | 100 条且 64 KiB | 500 条且 256 KiB |
| 单 bundle resource read | 8 MiB | 32 MiB |
| invocation aggregate resources | 16 MiB | 64 MiB |

redirect hop 计入 transport hops。CPU、wall 和单请求时间使用 monotonic clock；invocation wall 是真实墙钟 deadline，不累加并发请求的重叠时间。请求 body、响应 body、output、log 和 host callback 必须在大块分配、DNS 或 transport 前尽可能预留；stream 累计超限立即取消。

host callback 总数、module/source 大小、Promise job 和 timer 预算必须在 ADR-005 contract 中补齐默认值与硬上限，不能留作 adapter 无界面。resource 预算在解压、解码和跨 isolate 复制前强制，不能只依赖 QuickJS heap。

## 12. Invocation、取消与原子提交

每个 invocation 有不可复用的 run ID、deadline、cancel state 和 Credential Store transaction overlay。同一 run 内读取必须看到自己的 staged write/delete；其他 invocation 在提交前不可见。

只有同时满足以下条件才可原子提交持久化副作用：

1. capability 正常返回；
2. run 未取消、未超时且 grant/epoch 仍有效；
3. output 在预算内完成严格 JSON 序列化；
4. output 通过 manifest 指定的 exact schema/version；
5. Credential Store transaction commit 成功。

任一条件失败均 rollback overlay。网络请求及远端已产生的效果无法回滚。取消顺序必须是：标记 run cancelled、关闭新 host call admission、取消 transport 和 stream、拒绝 pending host promise、丢弃 overlay、终止并销毁 isolate。所有异步 completion 在向 JS 交付结果或提交副作用前必须再次核对 run ID、deadline 与 grant epoch。

## 13. 参数与输出

invocation 参数在创建或调度 QuickJS 前按 capability params schema 校验。capability 只能返回 JSON-compatible value；`undefined`、BigInt、function、symbol、循环引用、NaN 和正负 Infinity 稳定失败，不得按 `JSON.stringify` 语义静默删除字段或转为 `null`。

宿主按 serialized output budget 有界编码、解析后执行 exact schema/version 校验。成功结果包装为不可伪造的 `ValidatedCapabilityOutput`；UI、缓存和任何 export API 只接受该类型。schema failure 整体失败，不裁剪、不部分接受，也不提交 invocation overlay。

## 14. 日志与诊断

所有 build 都可以保留 adapter 净化正文。允许 level 固定为 `debug | info | warn | error`；非法 level 归一为 `info`。日志受 §11 的条数和总字节预算，每条在任何 sink 前先按 UTF-8 有界截断，再执行统一 sanitizer。

sanitizer 必须位于内存环、控制台、UI、回调、文件或遥测等所有 sink 之前。URL query、fragment、userinfo、cookie、认证 header、request/response body 和已知 secret pattern 不进入 host log；network 摘要只保留 method、canonical scheme/host/非默认 port、净化 path、status 和稳定 error code。

净化不能识别任意编码、拆分或混淆后的秘密。受信 adapter 可以主动把秘密写成 sanitizer 无法识别的文本；保留所有 build 的净化正文意味着明确接受该残余泄漏风险，不得把日志系统描述为 DLP。

## 15. 明确不保证

- manifest 网络门限制 exact host/path/method 和资源，不检查获准请求中的秘密内容；
- DNS 地址不分类阻断，不保护用户本机、LAN 或 metadata endpoint 免受获准 host 的解析变化；
- QuickJS 隔离保护宿主和旁路能力；Credential namespace 只保护未声明的跨 adapter 访问，不保护 adapter 自身 namespace 或已声明跨域范围中的内容；
- Web-compatible API 不等于浏览器 Fetch Standard 或浏览器安全模型；
- 取消和事务 rollback 不撤回已经发送到远端的请求或远端副作用；
- 日志净化降低意外泄漏，不阻止受信 adapter 主动编码外传。

## 16. 必测负例与迁移门

至少建立以下客户端生产 runtime 测试：

- 未受信 grant 在创建 isolate、evaluate module 和注册可调用 host API 前拒绝；
- isolate 按 digest/epoch 绑定、同 adapter 串行，更新/撤销/fatal 后旧 globals 和 pending jobs 不复活；
- remote import、Node/Dart/native module、文件、socket、FFI、WebView 和 UI 同步入口不可达；
- canonical URL 的 IDNA、userinfo、port、IPv4/IPv6、percent、dot segment、path prefix 与 transport URL 完全一致；
- exact host 可连接 public/private/loopback/link-local/metadata，并验证连接地址 pinning；
- manifest 外 scheme/origin/path/method 在 DNS/transport 前零调用；
- transport 不自动 redirect，三种 redirect mode 和每跳重新裁定生效；
- reserved framing header 拒绝，应用层认证 header 可用，跨 origin sensitive replay 被阻止；
- Fetch stream、AbortSignal、body 与 aggregate budget 在超限时终止 transport；
- `Set-Cookie` 多值原样可读，宿主不解析、不自动发送或持久化；automatic follow 不重放中间 cookie；
- 自身 Credential namespace 可访问，未声明或超出 `read`、`write`、`delete` 模式的跨 namespace 操作 fail closed；
- timeout、OOM、取消、schema failure 和 trust epoch 变化均 rollback Credential Store overlay；
- 非 JSON output 稳定失败，validated output 之前不能进入 UI/cache/export；
- 所有日志 sink 只收到截断净化文本且全局预算生效；
- 默认预算、manifest 扩容和绝对硬上限在所有目标平台使用同一 contract vectors。

V2 客户端网络、事务、输出和 runtime gates 成为 required checks 前，不得删除对应 V1 baseline。安全敏感实现和测试必须由人工实质性复核。

## 17. 结果与代价

该决策让 adapter 获得普通 JavaScript、Web-compatible Fetch、Node/爬虫式显式 cookie 管理、应用层认证 header 和长驻状态，同时把不可绕过边界收敛到 grant、Credential namespace、exact host rule、canonical URL、transport、预算、事务和 validated output。

代价是可信宿主需要实现比当前 V1 更完整的 Fetch/stream/cookie/transaction 生命周期；长驻 isolate 增加状态恢复复杂度；允许获准域名连接任何地址、并在所有 build 保留净化日志正文，则明确扩大本机网络和日志残余风险。
