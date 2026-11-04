# ADR-078 · 脚本声明 APPTunnel 账号与逐功能路由

- 日期：2026-11-03
- 状态：Accepted（所有者要求脚本配置账号连接信息、统一登录框、睿思显式依赖 APPTunnel）
- 承接：ADR-062、064、066、072、077。

SDK16 为账号增加 `appTunnel: {service, gatewayUrl, loginDomain, loginMode?, nodeCertificateSha256?}`。首片 service 固定 `hermes-atrust`，HTTPS origin 必须属于包网络声明，认证域固定，证书为可选节点叶证书 SHA-256 指纹；不声称支持客户端证书或 mTLS。连接配置属于批准 digest，UI 只读展示，不从用户输入重新定义学校网关。旧 SDK 拒绝新字段，旧账号路径保留兼容。当前固定认证控制面无法执行脚本 ipAllow，包含该字段的包拒绝新隧道声明。

可选 `loginMode` 默认为 password；web 直接打开固定网关的官方认证页面，必须使用空 loginDomain 且不允许 credentialReuse。现有CAS会话不会提供可靠域身份，因此首片不声称绑定特定CAS realm。非空密码域不能通过网页登录替代；密码模式仅空域允许用户主动选网页。SDK16登录必须明确accountId，status只能在当前目标account.session上下文调用；不能省略参数退回旧的任意网关管理页。

目标必须有固定 account.session login/status，不能同时声明普通 authentication。可选 credentialReuse 与目标 service/gateway/domain 必须完全一致，继续 ADR-077 的同包来源和单次验证。无复用时，`ctx.appTunnel.login(service,{accountId})` 使用统一宿主账号密码输入框，账号名称、说明、只读连接概要来自声明。保存密码和会话均由宿主控制；一次认证和在线检查成功后才能替换旧记录，取消、MFA或未知不覆盖旧值。可主动打开固定网关的官方网页登录。保存密码从不回填 UI/返回脚本。

能力和普通账号均可声明 `appTunnelAccountId` 引用同包已声明隧道账号。account.session 按 account 参数选择该账号依赖；其它能力按 capability 声明选择。依赖能力只使用目标 provider、网关、域及节点证书一致的会话，不受旧全局选择替代，不直连回退、不自动登录或重发。缺配置返回固定 app_tunnel_required 并给对应账号入口；网络检查失败保持 unknown，不推断源密码错误。账号管理自身不依赖它所建立的隧道。SDK16 无依赖能力保持直连；旧 SDK 的全局路由兼容保留。

设置不再直接通往 APPTunnel 管理；用户从脚本账号页进入明确的目标账号。核心负责有限固定表单、原生实现、身份/digest/网络/取消/存储与逐功能路由；脚本负责服务依赖、目标配置和实际学校检测。学校展示分级另见 ADR-079，不改变学校权限 scope。

验证包含 SDK 版本和交叉引用、不同网关/域/证书拒绝、依赖缺失不发直连、普通功能独立直连、身份切换与来源更新取消、单次认证/保存失败、原生表单与账号入口。合成验证不替代真实睿思/网关、真机与人工网络凭据审阅。
