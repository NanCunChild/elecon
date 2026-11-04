# Hermes / ZJU Connect 对齐记录

日期：2026-11-03。范围：ADR-062/064/066 的宿主 APPTunnel、账号状态和协议兼容性。本文是代码审计与自动验证记录；尚未完成真实学校网关登录或业务连通验收。

## 依据与许可

elecon 固定的 [Hermes-Atrust](https://github.com/ncc-devlab/Hermes-Atrust/tree/271a547d73c3839365a1995d1a6d72ed915e1458) 提交为 `271a547d73c3839365a1995d1a6d72ed915e1458`，MIT，具体本地修改和依赖见[原生桥 README](../../native/hermes_app_tunnel/README.md)。

本次查阅 [ZJU Connect](https://github.com/Mythologyli/zju-connect/tree/8576e7a16076c4175d6dbe276573a353cf7260be) 提交 `8576e7a16076c4175d6dbe276573a353cf7260be`。其 [LICENSE](https://github.com/Mythologyli/zju-connect/blob/8576e7a16076c4175d6dbe276573a353cf7260be/LICENSE) 是 AGPL-3.0；仅查阅协议行为，不复制其实现、引入 Go 库、打包二进制或改动现有依赖图。后续若采用其实现，须另定许可与分发边界。

## 当前差异

| 项目 | 对照证据与 elecon 现状 | 本轮结果 / 后续落点 |
|---|---|---|
| 账号失效分类 | ZJU Connect `authConfig` 区分 `10000004`、`75500002`。Hermes 原先仅识别后者；核心状态检查也忽略 `isLogin=0` | 已修复两类明确失效证据。已登录需 `onlineInfo` 匹配保存身份；网络错误、格式错误、未知业务码继续 unknown。没有自动提交密码 |
| HTTP 拒绝 | 对照实现将 `authConfig` 的 HTTP 401/403 当失效 | elecon 保守保留 unknown，避免把网关策略或中间设备拒绝误作密码失效；没有扩大为所有 HTTP 失败均重登 |
| SID 轮换 | 对照实现明确要求在最后一条控制面响应之后获取 SID 快照；原实现恢复后始终使用保存的 SID | **执行内已修复**：每次 TCP 握手读取当前认证 transport 的 Cookie jar，因此包含 authConfig/onlineInfo/clientResource 的 SID 更新；缺失/非法即停止，不恢复旧 `Stored.sid`。合成 TLS 对端已核验轮换后的 SID 和删除后的拒绝。**ADR-075 已补**：status 检查返回最后响应后的 Cookie jar，按 Profile/学校/代际/原记录修订受保护持久化，下一次检查及重启复用新值。资源刷新/建链路径的跨调用发布和完整并发单飞仍待实施；不宣称长期续期完成 |
| 控制面签名 | 对照实现读取 antiMITM 数据，对 reportEnv 发送 `X-Request-Sig` | 当前固定 Hermes 不解析该协商，也不发此头。**待实施**：独立协议规格、合成向量及真实网关验证。不能把数据面随机签名 key 当作此控制面 key |
| TCP 版本 | 对照实现从 `/public/manifest` 判断 zero-RTT 能力及启用项，区分传输模式 | Hermes 当前使用固定 init/destination/probe 与帧化流。**待实施**：显式版本协商和两种模式的合成对端测试；未知版本停止，不能猜测然后重放业务字节 |
| 会话刷新 | 对照实现提供非交互 Refresh，获取新 SID/Cookie | 当前资源表定时刷新不是账号续期；没有受保护会话续期发布。需先解决 SID 一致性、取消和单飞，明确失败分类；续期不提交已保存密码、不自动重发业务请求 |
| TLS 与路由 | elecon 网关正常 PKI，节点正常 PKI 或明确证书 SHA256；原目标 TLS 由 Dart 验证；origin/IP 授权仍由宿主执行 | 保持 ADR-062 边界，不能为了协议“对齐”引入跳过验证、直连回退、公共代理或系统 VPN |
| 浏览器 | 普通脚本 WebView 仍未接入所选 APPTunnel；网关登录浏览器属于固定管理面 | 当前隧道模式明确拒绝普通浏览器直连；嵌入页面/静默认证接线必须覆盖子资源、跳转、WebSocket 和取消后才能开放 |

失效分类与控制面签名证据：[auth/request.go](https://github.com/Mythologyli/zju-connect/blob/8576e7a16076c4175d6dbe276573a353cf7260be/client/atrust/auth/request.go)。SID 和非交互刷新证据：[auth/refresh.go](https://github.com/Mythologyli/zju-connect/blob/8576e7a16076c4175d6dbe276573a353cf7260be/client/atrust/auth/refresh.go)、[client.go](https://github.com/Mythologyli/zju-connect/blob/8576e7a16076c4175d6dbe276573a353cf7260be/client/atrust/client.go)。TCP 模式证据：[server_version_test.go](https://github.com/Mythologyli/zju-connect/blob/8576e7a16076c4175d6dbe276573a353cf7260be/client/atrust/auth/server_version_test.go)、[tcptunnel.go](https://github.com/Mythologyli/zju-connect/blob/8576e7a16076c4175d6dbe276573a353cf7260be/client/atrust/tcptunnel.go)。这些差异说明不能宣称 Hermes 与当前 ZJU Connect 全面对齐，也不能仅凭 onlineInfo 成功宣称隧道可用。

## 已完成验证

- `cargo test --locked -p elecon-hermes-app-tunnel`：15 项通过。新增失效码正反例、明确 loggedOut 无额外请求；本机 TLS 对端验证资源响应轮换后的 SID、删除 live Cookie 后拒绝旧 SID、目标地址固定、一次性 UDS、取消和凭据脱敏。
- `cargo test --locked -p atrust-auth -p atrust-client -p elecon-hermes-app-tunnel`：74 + 10 + 15 = 99 项通过；严格 Clippy 与 Linux 动态库构建通过。
- `flutter test test/transport`：31 项通过，覆盖 APPTunnel 设置、学校隔离、拒绝浏览器绕过、账号保存、真实 Linux C ABI 及窄屏页面。修复后的 Linux 库另经 `flutter test --no-pub test/transport/hermes_native_test.dart`，4 项真实 C ABI 测试通过。
- ADB 只读检查确认用户指定设备可连接，API level 为 35；设备标识不进入仓库。未提取凭据、未请求学校网关、未把设备连通当作原生库或 Android 17 验收。

## 真实网关验收顺序

1. 固定待测原生库与脚本 digest，使用现有受保护账号入口；只记录固定阶段码、结果类别和请求次数，不保存原始 Cookie、密码、SID、节点私密资源表或学生数据。
2. 单次主动登录验证：正确密码、需要 MFA、错误密码停止、取消和旧身份晚到结果失效；网页登录 fallback 独立验证。保存账号不等于登录成功。
3. 只读目标分层验证：账号身份确认 → 资源授权 → 隧道 DNS → 数字地址拨号 → 原目标 TLS → 一个授权的只读请求。每层失败保留分类，禁止自动切直连。
4. 执行内 SID 轮换已通过合成对端；继续补跨调用持久化、两种 TCP 模式、控制面签名和取消，再在同一小预算下检查真实网关。需追加这些实现后才能声明对应兼容性。
5. 根证书/节点 pin 不匹配、未授权域名、退出、切 Profile/学校及选择变化应关闭在途工作；控制或消息类操作不用于连通探测，不因失败重放。

真机步骤、真实学校可用性、核心/网络人工实质审阅分别记录；本次自动测试没有替代它们。

## 2026-11-03 追加：状态检查 SID 发布（ADR-075）

原生桥 16 项测试和严格 Clippy 通过，新增 live Cookie 轮换/删除与原身份材料保留。客户端定向 14 项（含 SDK14 两项声明回归）通过，覆盖状态不返回会话秘密、下一次调用/加密重启读取新 SID、持久化失败与身份不匹配保留旧材料。真实网关、资源轮询长周期续期与人工审阅仍独立待验收。
