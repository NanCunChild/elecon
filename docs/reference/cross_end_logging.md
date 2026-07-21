# 跨端日志策略（client / campus 中继）

> 状态：实现参考（非 ADR）。约束来自红线 #1/#2/#3 与「观测可调试、凭证不外泄」。

## 目标

- **client 唯一观测 sink**：`DevLog`（环缓冲 + Settings 查看页）。
- **默认脱敏**：URL 无 query/fragment/userInfo；cookie 值仅长度；无 body、无凭证原文。
- **debug 可关闭脱敏**（仅本机环缓冲）：联调时保留 query / cookie 原文；release 强制 `redact=true`。
- **campus 中继**不记凭证、不记 body；成功路径只记 method + host/path + status。

## Client（`client/lib/core/debug/dev_log.dart`）

| 类别 | release 写入 | debug 写入 | 典型来源 |
|------|-------------|-----------|----------|
| `network` | ✅ | ✅ | `DirectTransport` |
| `runtime` | ❌ | ✅ | 会话/装载诊断摘要 |
| `webview` | ❌ | ✅ | WebView 登录页（已打码消息） |
| `adapter` | ❌ | ✅ | QJS `onLog` / 运行时诊断 |

### 脱敏 API

- `formatUrlForLog(raw, {required redact})` — 真源
- `sanitizeUrlForLog(raw)` — `redact: true` 的薄包装（transport 等）
- `maskCookieValue(value, {required redact})` — cookie 打码

`DevLog.redact` 默认 `true`；`setRedact(false)` 仅 `kDebugMode` 生效。  
**注意**：开关只影响**之后**写入的条目；已进环缓冲的历史不变。

### 接线约定

1. **Transport**：`DirectTransport` → `DevLog.network`（始终走 `formatUrlForLog(..., redact: log.redact)`）。
2. **Adapter 执行**：`SessionController._runOn` 默认把 `onLog` → `DevLog.adapter`、`onDiagnostic` → `DevLog.runtime`；调用方可叠加自己的回调。
3. **WebView 登录**：页面本地面板 + `DevLog.webview`；URL/cookie 用 `formatUrlForLog` / `maskCookieValue` 且读 `DevLog.instance.redact`。
4. **UI**：`DevLogPage` 提供筛选（全部 / 仅网络）与 debug 脱敏开关；文案与 Settings 入口一致。

### 禁止

- 日志中出现 cookie/token 原文（除非 debug 且用户主动关脱敏）。
- 把 DevLog 同步到公网或 telemetry（当前无远程上报；若引入须另开 ADR）。
- adapter / UI 直读凭证值再写入日志。

## Campus 中继（`server/src/campus`）

- 授权中继**无状态、零凭证落盘**（红线 #2/#3）。
- 访问日志建议字段：`method`、`path`（无 query 或仅白名单键）、`status`、`latency`、请求 ID。
- **不得**记录：`Authorization`、`Cookie`、请求/响应 body、重定向中间 token。
- 错误日志只记错误码与阶段，不回显用户输入中的密钥材料。

## 与「复制到剪贴板」

- debug：可复制可见条目（用户知情后用于 issue）。
- release：网络日志本身已无参；复制仍不得包含 body/凭证（因写入路径已保证）。

## 相关代码

- `client/lib/core/debug/dev_log.dart`
- `client/lib/session/session_controller.dart`（`_runOn` 桥接）
- `client/lib/core/transport/direct.dart`
- `client/lib/ui/login/webview_login_page.dart`
- `client/lib/ui/settings/dev_log_page.dart`
- `client/test/dev_log_test.dart`
