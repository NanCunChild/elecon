# ADR-062 · APPTunnel 基座选择与核心连接边界

- 日期：2026-11-02
- 状态：Accepted（所有者授权核心选择，并确认首版接入 Hermes）；实现与真实网关验收分别记录。
- 承接：ADR-034、041、044；旧 ADR-003/032 和 Probe-002 只作为历史材料。

## 范围

VPN 在本决策中仅指 APPTunnel：elecon 自己的请求通过应用内 TCP 隧道，不创建系统 VPN/TUN、不更改全局路由、不代理其他应用、不加载脚本提供的原生模块。核心按当前 Profile/学校保存明确选择，默认直连；选中的基座失效、缺失、未编入或设置损坏时停止请求，不能自动回落直连。

核心登记可用基座及只读名称/可用性，UI 选择稳定基座 ID；学校脚本不指定任意插件路径、代理 URL 或隧道句柄。设置只保存非密 ID，认证材料仍需当前 Profile/学校的受保护存储；首片不增加学校脚本权限或接收明文隧道凭证的 UI。

## 接入

受信源码 HTTP/WSS 共用本次执行的 APPTunnel 会话。基座只提供解析和指定地址的 TCP 连接，HTTP、目标 SNI/证书验证、原始 origin/IP 授权、重定向、预算仍由现有宿主管理。校内 DNS 必须来自所选基座，不偷偷使用公网 DNS；返回的地址仍经过包的 IP/CIDR 限制。选择在一次执行内固定，不根据失败自动切基座或重发命令。

切换设置、学校或 Profile、退出及取消撤销受信源码的在途连接；晚到的解析/拨号/基座初始化关闭且不得继续请求。原生 WebView 尚无同等的逐会话接线，选择 APPTunnel 时普通学校脚本的浏览器调用明确报不可用，不能悄悄直连；Hermes 网关认证是独立受控的官方网页登录。V1 业务/认证不支持 APPTunnel，选择隧道时拒绝执行；已在执行的 V1 操作无法取消，因此结束前拒绝切换网络设置。异步装配期间重核代际，旧认证桥在切换时停止且不再收割。

## 基座研究与迁移

采用 [Hermes-Atrust](https://github.com/ncc-devlab/Hermes-Atrust/tree/271a547d73c3839365a1995d1a6d72ed915e1458)，固定提交 `271a547d73c3839365a1995d1a6d72ed915e1458`：仓库有 MIT LICENSE，`atrust-client` 提供 TCP dial/shutdown，属于应用内字节流；上游没有移动端 FFI 桥，节点 TLS 只有 Verify 与 DangerousAcceptInvalidCertificates。本轮在 `native/hermes_app_tunnel/` 随仓固定必要 MIT 源码，增加受控 JSON C ABI/一次性 UDS、指定地址 dial 和完整节点证书 SHA256 校验；源站 TLS 由 Dart 完整校验。未配置指纹使用正常 PKI，错误指纹失败；不提供关闭校验选项。本地 Hermes-aTrust-Server 是对端服务端，不是客户端基座。

首片 Android 构建编入 Hermes，Linux 编译用于原生桥回归；未编入其他平台时明确不可用。可用性核对真实动态库和 ABI 版本 1，保存的基座 ID 不代替可用性。设置页提供网关 HTTPS origin、可选节点证书 SHA256 和官方页面登录；CAS/MFA 完成后用户触发检查，核心读取网关 Cookie，Hermes 核验 online_info 并取得会话材料后进入 H/S/M 存储。UI 只有网关/指纹及状态，学校脚本拿不到材料；退出/清除/切身份取消在途认证与旧会话。指纹由用户从可信途径配置，更换证书后需重新核对；不自动信任首见证书。

Dart 侧 HTTPS 显式 SecureSocket 升级，不能沿用旧 ADR 对 connectionFactory 自动 TLS 的假设。当前固定每次执行一个会话，按网关资源授权域名/IP，校内 DNS 走隧道；资源不匹配不自动分流直连。一般学校登录可先在直连完成，再启用 APPTunnel；普通 WebView 经隧道接线、其他平台打包及真实学校网关验收仍待实施。

## 验证与回滚

合成基座通过真实本机 HTTP/TLS/WSS 测试解析/拨号、原目标证书校验、拒绝越界、无直连回落、取消及晚到连接销毁；设置覆盖持久化失败、损坏、Profile/学校隔离与中英文页面。没有真实网关登录、真实学校请求或系统 VPN 操作。恢复直连需用户明确选择；核心/网络实现须人工实质审阅后合并。

2026-11-02 自动验证：相关客户端 94 项回归、旧认证/存储与隧道路径组合 36 项、46 项超星模块测试、71 schema / 69 registry 引用 golden 与 codegen同步通过；定向 Dart analyze 无问题。Hermes 原生 8 项回归覆盖真实本机 TLS/pin、协议目的帧/UDS、DNS与取消；Dart 实际 Linux C ABI 版本/并发/固定错误已验证。Android ARM64 Debug APK 构建通过，逐字节核对包内剥离后的 Hermes 库、MIT/依赖许可证资产与源文件；主/Apple两套锁文件 enforce解析通过。真网关、CAS/MFA、各平台真机及人工实质审阅仍待验收；自动测试不代表网关接受 provisional 签名材料。
