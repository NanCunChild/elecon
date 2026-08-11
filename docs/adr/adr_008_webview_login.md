# ADR-008：宿主 WebView 登录与凭证收割

- **状态**：提议（Proposed）
- **日期**：2026-08-11
- **依赖**：[ADR-003](./adr_003_core_security_boundary.md)、[ADR-004](./adr_004_credential_store.md)、[ADR-005](./adr_005_adapter_v2.md)

## 1. 决策

WebView 只由宿主创建和控制。adapter 可按 Manifest V2 请求一个登录计划，但永远拿不到 WebView controller、DOM、cookie jar、任意 JavaScript 注入或 native bridge。

登录必须由用户可见动作启动。宿主负责：

- navigation allowlist 和每跳 canonical URL 检查；
- 禁止未声明 popup、新窗口、下载、外部 scheme 和 deep link；
- TLS 错误 fail-closed；
- 成功 URL、cookie/query 收割和超时裁定；
- 将结果原子写入 Credential Store 复合键；
- 取消、失败、账户切换和完成后销毁临时 profile。

local trusted adapter 可以请求宿主登录能力，不增加单独高风险确认；其在收割后可通过 Credential Store 读取结果。整体风险由用户的 bundle digest trust 承担。

## 2. 收割边界

- 只收割 manifest 静态声明且宿主验证过的学校域、cookie 名和 callback 参数。
- HttpOnly cookie 只能经平台宿主 API 获取，不向 adapter 暴露 WebView 内部对象。
- UI、历史、日志和错误不得显示含 query/token 的完整 URL。
- WebView cookie store 与 HTTP client/Credential Store 的同步必须是显式事务，禁止部分提交。

## 3. 平台验证

Android、iOS、OHOS 分别验证 HttpOnly、Secure、SameSite、多域 SSO、popup/iframe、service worker、远程调试和 profile 隔离。V1 probe 是时间敏感历史证据，不能替代新真机验证。

## 4. 必测负例

- allow 外导航、TLS 错误、popup/download/external scheme 被阻断。
- 多账户 cookie 不串号；成功 URL 出现但 cookie 未稳定时不提前提交。
- release WebView 远程调试和任意 JS bridge 关闭。
