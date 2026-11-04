# 脚本声明账号凭据复用（SDK15）

依据 [ADR-077](../adr/adr_077_declared_account_credential_reuse.md)。[合成模板](../../adapters/_template/trusted/credential-reuse/manifest.json)提供源学校账号和目标 VPN 账号；示例域名不可用于真实登录，学校源账号认证刻意留为未配置。

目标账号在 manifest 声明 `credentialReuse`：

```json
{
  "sourceAccountId": "school",
  "service": "hermes-atrust",
  "gatewayUrl": "https://vpn.example.invalid",
  "loginDomain": ""
}
```

源必须为同包另一个 `authentication.savedPassword:true` 的账号，目标必须绑定 `account.session` 的显式 login 和只读 status；两者都需有明确名称和 instructions。网关必须是包 network.origins 中的精确 HTTPS origin。空 loginDomain 仅适用于目标网关恰好提供一个密码域。不得猜测学校 IDS 与 VPN 的账号关系，作者应先确认目标网关、域及实际认证方式。

用户点击目标登录后，脚本调用 `ctx.appTunnel.login('hermes-atrust', {accountId:'vpn'})`。宿主校验当前批准来源及目标登录绑定，再将已保存的源用户名和密码直接交给 Hermes；脚本和页面不会收到此复用调用的密码。源密码未保存时返回 `authentication_required`，脚本应引导用户登录源账号。复用不会创建第二份密码记录、修改源恢复门或自动选择隧道路由。

宿主执行一次密码认证，再验证目标在线状态，成功后才保存目标会话并返回标准账号状态。失败、未知或取消保留旧会话；本次返回 unknown/expired 时不得用旧会话状态冒充本次成功。脚本仍承担实际学校业务检测义务：IDS 有效不代表 VPN 有效，VPN 有效也不代表某个教务系统有效。需要目标业务探测时应独立执行只读探测，不自动重放发送、控制或签到请求。后台调用、普通刷新和 status 不能触发密码复用。

旧 SDK 包无需迁移。使用此功能须升至 SDK15、更新包版本并重新批准。当前没有为西电生产包声明未经验证的网关/复用关系。合成测试与模板打包可验证代码路径，真实学校账号与人工凭据/网络审阅仍需分别完成。

首片 Hermes 控制面暂不接受脚本 IP/CIDR 规则，因此含 `network.ipAllow` 的包禁止声明凭据复用；需要该约束时应等待固定控制面实现。不能静默忽略包的 IP 限制。
