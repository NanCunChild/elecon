# 脚本声明隧道账号（SDK16）

依据 [ADR-078](../adr/adr_078_script_tunnel_accounts.md)，宿主提供固定 Hermes/aTrust 服务，脚本负责声明学校网关、登录方式和哪些服务需要此连接。[合成模板](../../adapters/_template/trusted/tunnel-account/manifest.json)与[源码](../../adapters/_template/trusted/tunnel-account/main.js)可直接打包检查；`.invalid` 示例域名不能用于实际登录。

账号的 login/status 仍绑定同包 `account.session`，参数分别为 `{account:'vpn',operation:'login'}` 和 `{account:'vpn',operation:'status'}`。额外声明：

```json
"appTunnel": {
  "service": "hermes-atrust",
  "gatewayUrl": "https://vpn.example.invalid",
  "loginDomain": "",
  "loginMode": "password"
}
```

网关必须属于包 network.origins，且是精确规范HTTPS origin；认证域为空仅表示密码登录时由网关唯一密码域决定。可选 `nodeCertificateSha256` 是64位小写十六进制叶证书指纹，作用于隧道节点；省略时使用系统证书验证，不能表示忽略证书错误。当前不支持客户端证书或mTLS，也不接受 `network.ipAllow` 与此固定控制面组合。

password 模式调用 `ctx.appTunnel.login('hermes-atrust',{accountId:'vpn'})` 后使用统一原生账号密码框。脚本名称、说明、网关及进阶连接概要均来自批准声明；用户只输入用户名和密码并选择是否保存。已保存密码不回填UI。一次认证和目标在线检查完成后，宿主才原子保存会话及可选密码；失败、未知、取消不覆盖旧记录。脚本收到标准账号状态，不取得原生隧道秘密。

web 模式直接打开固定网关的官方认证页面，适用于学校CAS。首片必须 `loginDomain:''`、不得声明credentialReuse；这只验证网关会话，不声称验证某个CAS认证域。非空密码域也不能通过网页fallback冒充该域登录。西电IDS/CAS与网关本地密码域是不同认证路径，不能仅因账号名称相似就将IDS密码提交到本地密码域。

学校服务所需能力声明 `appTunnelAccountId:'vpn'`，普通账号也可同样声明依赖。例如论坛能力和论坛账号各自声明，才能覆盖 `forum.session` 和 `account.session` 两个入口。目标必须是同包的appTunnel账号，不能引用普通保存密码账号或形成循环。目标账号管理自身不依赖隧道。

宿主在执行前匹配当前Profile/学校的网关、非空认证域及证书配置，仅为该能力使用对应路由；缺会话返回 `app_tunnel_required`，界面给出脚本账号入口。连接失败没有直连fallback，不自动登录、不重放业务请求。SDK16未声明依赖的能力使用直连，旧全局网络选择不影响它们；SDK15及以下保持原路由兼容。设置页不再直接进入隧道配置，登录从脚本账号页进入。

安装审查展示固定连接目标及依赖；更新网关、证书、域、学校展示或依赖均需新包版本并重新批准。学校分组的 `school` 元数据只是展示，原 `schoolId` 仍决定凭据/授权/缓存范围，详见 ADR-079。自动测试与模板不替代真实学校、真机及人工凭据/网络审阅。
