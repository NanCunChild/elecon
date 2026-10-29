# ADR-034：受信学校脚本、显式网络范围与浏览器操作

- **Decision**：Accepted（2026-10-29；仓库所有者在本次会话确认凭据直接访问、用户侧载、域名/IP 白名单，并授权无人值守分阶段实现）
- **Landing**：见 `docs/planning/trusted_scripts.md`；Accepted 不代表实现人工安全签收。
- **覆盖**：ADR-000 §3.3、ADR-002/009/018/022/023/026/033 中与新 `elecon-script/1` 路径冲突的约束；既有 official bundle 路径在迁移期间保持原有语义。

## 1. 目标与范围

让学校接口、认证中间值、校本签名和页面流程主要由普通异步 JavaScript 处理，避免继续扩充凭据不可见的数据流 DSL。保留背景执行、身份隔离、资源预算、平台存储、标准输出校验和公网零凭据。脚本受信意味着可读、改、泄漏当前授权身份内的数据；网络清单限制目标，不承诺内容防泄漏。

本决策只为客户端增加一个可实际使用的新路径，不将 V2 分支或 elecon-r 整体合入。elecon-r 只借鉴异步页面执行、DOM 查询和开发体验；新代码自行实现，使用现有依赖，无新增第三方依赖。服务端不执行新脚本。

## 2. 源码包与迭代

首版分发为 UTF-8 JSON 文本（`.elecon.json`），含 `format: elecon-script/1`、manifest 和 source。manifest 使用 `sdkVersion: 1`，声明 id、严格三段 SemVer version、schoolId、name、network、browser 与 capabilities（id、schema、schemaVersion）。所有来源的脚本均由同一 parser 校验后执行。源码包上限 1 MiB；输出上限 4 MiB；JSON 格式及字节数在解析前检查。

包内容的 SHA-256 digest 绑定安装授权。安装前不能创建运行时或执行源码。用户查看学校、版本、域名/IP、页面权限、凭据访问说明后确认安装；显式导入新版是一次更新授权。相同 id 只允许更高版本更新，降级拒绝，同版本不同内容拒绝，相同内容可幂等导入。包不能通过自报相同 id 接管其他学校或身份；不同 schoolId 的同 id 更新拒绝。已安装源码、manifest、digest 和启用状态原子持久化，重读时重新校验。首版不提供无人确认的自动更新，不要求用户给本地脚本签名；official V1 分发仍验签。后续 official 新格式分发、第三方发布者自动更新另开决策。

## 3. 凭据范围与持久化

脚本通过 `ctx.credentials.get/set/delete/list` 读取和写入真实值。宿主隐式绑定当前学校身份，脚本不能传入或选择身份。首版只允许在当前选校会话中运行该学校脚本，同校脚本的安装确认明确包含该学校凭据访问；不建立跨学校访问权限语言。

宿主复用现有 CredentialStore 和 H/S/M 保护选择；加密主密钥永不暴露。用户取消持久化时继续仅内存使用，不静默明文落盘。脚本的键与旧登录凭据可共存，读取可包括过期状态以便自行刷新；写入只属于当前学校。登出/切校/禁用/卸载使已运行调用失效，晚到回调不能写回。修改 JS 凭据可见性不意味着给 UI 交付完整 store。

## 4. 域名、IP 与 HTTP

network.origins 是精确 HTTP(S) origin 列表（scheme、host、port；不支持 host wildcard、userinfo 或路径），支持域名、IPv4 与 IPv6 literal；HTTP 必须显式列出。可选 network.ipAllow 为精确 IP/CIDR 列表；出现时是额外约束，实际连接地址必须命中；未出现则允许已声明 origin 的正常解析结果，包括校内地址。空 ipAllow 表示不允许任何连接。每个 redirect hop 重验 origin，解析结果绑定实际 socket；TLS 仍验证原 hostname，禁止忽略证书错误。不使用公共/私有地址分类代替学校声明。

宿主提供有限 fetch 语义：method、headers、文本请求 body、status、URL、原始多值响应头和 Set-Cookie、text/json/bytes/arrayBuffer；支持 manual/follow/error redirect，所有跳计入预算。响应保留原始字节；UTF-8 / 显式 Latin-1 可直接 text/json，未知编码由脚本用 bytes 处理，不因宿主缺少解码器丢弃响应。Cookie/Authorization 可由脚本显式构造，不经旧 Broker 注入、Masker 或句柄。禁止设置协议路由/framing 头；跨 origin 自动重定向不重放认证头或敏感请求体。单次调用的请求总量、并发、超时、body 和响应字节有界。

## 5. 浏览器与 DOM

仅 manifest.browser=true 的脚本得到 `ctx.browser`。API 包含 open、evaluate（页面 JS）、text/queryAll/exists/waitFor 和 cookies；原生 controller 不交付给脚本。所有操作异步转发给宿主创建的可见页面，用户可手工登录和完成验证码。一个页面执行一个学校身份会话，关闭、取消、切校后失效；首版不并行多个学校浏览器身份。

页面导航与新窗口受 network.origins 约束；IP 约束的脚本不能使用系统 WebView（无法证明 socket 地址 pinning），须稳定报告不支持并使用 ctx.fetch。WebView 的子资源、iframe、service worker 和页面网络遵循浏览器自身机制；该模式明确不声称全部页面请求均经过 ctx.fetch 或执行与原生 HTTP 相同的 IP 限制。浏览器权限展示明确说明这一区别。浏览器权限是对 origin 内页面程序的信任，不能作为强内容 DLP。

浏览器会话复用用户可见登录，释放时清理应用 WebView 会话。首版使用独占浏览器租约，避免与旧登录 WebView 或另一个脚本共享活动身份；平台可用性显式报告，不以 Android mock 测试声称跨平台真机验收。

## 6. 执行与输出

统一 async capability handler 在背景 QuickJS isolate 执行，提供 ctx.fetch、credentials、browser（可选）、now 和受控日志。未信任/禁用/内容不符的包不执行；输出必须是严格 JSON，并通过 manifest 的标准 schema/version 校验。不再给新脚本设置 declarative/imperative、opaque handle 或 mandatory Masker。首版只包含包内单个 ESM 源码及内置 elecon:html 模块，不开放远程 import、FFI、raw socket 或任意文件系统。

取消/超时关闭宿主回调并终止调用；宿主错误不回传未净化 URL/凭据。已知凭据从日志中抹除，但不承诺识别脚本主动编码的数据。远端网络副作用无法回滚。原有数据卡片继续复用，脚本工具支持通用结果展示；不让一个通知接口失败阻断其他入口。

## 7. 验收与审阅

每阶段提交使用 --no-gpg-sign，commit 带 Assisted-by。覆盖包解析/版本/信任更新、真实 QuickJS 凭据与请求流程、域名/IP/CIDR/redirect、本地 HTTP transport、DOM bridge 取消/关闭、切校/登出隔离、安装恢复和错误输出。合成夹具不访问真实学校和账号。保留原有路径回归；新路径实现测试和独立 agent 审阅不等于人工安全签收或生产合并授权。
