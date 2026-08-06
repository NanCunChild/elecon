# 跨端日志策略（client / campus 中继）

> 状态：实现参考（非 ADR）。约束来自红线 #1/#2/#3 与「观测可调试、凭证不外泄」。

## 目标

- **client 唯一观测 sink**：`DevLog`（环缓冲 + Settings 查看页）。
- **永久凭证脱敏**：URL 无 query/fragment/userInfo/path session 参数；cookie 使用固定占位符；无 body、无凭证原文或长度。
- debug 只能扩展日志类别，不能关闭凭证脱敏。
- **campus 中继**不记凭证、不记 body；成功路径只记 method + host/path + status。

## Client（`client/lib/core/debug/dev_log.dart`）

| 类别 | release 写入 | debug 写入 | 典型来源 |
|------|-------------|-----------|----------|
| `network` | ✅ | ✅ | `DirectTransport` |
| `runtime` | ❌ | ✅ | 会话/装载诊断摘要 |
| `webview` | ❌ | ✅ | WebView 登录页（已打码消息） |
| `adapter` | ❌ | ✅ | QJS `onLog` / 运行时诊断 |

### 脱敏 API

- `formatUrlForLog(raw, {required redact})` — 真源；兼容参数不能放宽永久边界
- `sanitizeUrlForLog(raw)` — `redact: true` 的薄包装（transport 等）
- `maskCookieValue(value, {required redact})` — 固定占位符，不泄漏长度
- `sanitizeLogMessage(message)` — generic/runtime/webview/adapter/error 入 sink 前统一净化

`DevLog.redact` 恒为 `true`；`setRedact(false)` 为源兼容 no-op。

### 接线约定

1. **Transport**：`DirectTransport` → `DevLog.network`（始终走 `formatUrlForLog(..., redact: log.redact)`）。
2. **Adapter 执行**：`SessionController._runOn` 默认把 `onLog` → `DevLog.adapter`、`onDiagnostic` → `DevLog.runtime`；调用方可叠加自己的回调。
3. **WebView 登录**：页面本地面板 + `DevLog.webview`；URL/cookie 用 `formatUrlForLog` / `maskCookieValue`。
4. **UI**：`DevLogPage` 只提供类别筛选；UI 与剪贴板消费的均为 sink 内已净化副本。

### 禁止

- 任何 build mode 或日志类别中出现 cookie/token 原文或凭证长度。
- 把 DevLog 同步到公网或 telemetry（当前无远程上报；若引入须另开 ADR）。
- adapter / UI 直读凭证值再写入日志。

## Campus 中继（`server/src/campus`）

- 授权中继**无状态、零凭证落盘**（红线 #2/#3）。
- 访问日志建议字段：`method`、`path`（无 query 或仅白名单键）、`status`、`latency`、请求 ID。
- **不得**记录：`Authorization`、`Cookie`、请求/响应 body、重定向中间 token。
- 错误日志只记错误码与阶段，不回显用户输入中的密钥材料。

## 与「复制到剪贴板」

- debug：可复制可见条目（用户知情后用于 issue）；条目已先经过永久净化。
- release：网络日志本身已无参；复制仍不得包含 body/凭证（因写入路径已保证）。

## 相关代码

- `client/lib/core/debug/dev_log.dart`
- `client/lib/session/session_controller.dart`（`_runOn` 桥接）
- `client/lib/core/transport/direct.dart`
- `client/lib/ui/login/webview_login_page.dart`
- `client/lib/ui/settings/dev_log_page.dart`
- `client/test/dev_log_test.dart`
