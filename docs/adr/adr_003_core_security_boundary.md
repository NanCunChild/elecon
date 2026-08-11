# ADR-003：可信核心、QuickJS 与宿主网络安全边界

- **状态**：提议（Proposed）
- **日期**：2026-08-11
- **依赖**：[ADR-001](./adr_001_project_shape.md)、[ADR-002](./adr_002_execution_trust.md)

## 1. 决策

adapter 使用普通异步 JavaScript，在背景 QuickJS isolate 中执行。可信核心只保留不可绕过的执行准入、host API、网络出口、资源预算、标准输出校验和平台能力。

adapter 不获得 Node/Dart 模块、文件系统、进程、raw socket、WebView controller、原生 FFI、动态原生模块或 UI 线程同步执行能力。

所有网络只经过宿主 `ctx.fetch`。宿主在 transport 调用前强制：

- URL canonicalization；
- HTTPS 与允许的 scheme；
- origin、port、path 和 method；
- userinfo、IDN、默认端口、点段和百分号编码规范；
- 重定向逐跳重新裁定；
- DNS 解析后的 loopback、link-local、私网和 IPv4-mapped IPv6 策略；
- 请求数、并发、请求体、响应体、总时间和取消预算。

transport 不得自动跟随重定向。取消或 deadline 后，Promise job、cookie 写入、Credential Store 写入和回调不得继续提交副作用。

adapter 输出在进入 UI、缓存或 public 数据路径前必须通过 capability 对应的标准 schema。

## 2. 明确不保证

宿主网络门限制目标和资源，不是内容 DLP。受信 adapter 可以把凭证编码进获准 origin 的 URL、header 或 body，核心不承诺识别或阻止。

QuickJS 隔离保护宿主进程和旁路能力，不保护已授予受信 adapter 的 Credential Store 内容。

## 3. 日志和诊断

宿主日志必须净化 URL query、fragment、userinfo、cookie、认证 header 和 body，并限制 adapter 日志长度与速率。任意编码后的秘密无法通用识别，不作过度承诺。

## 4. 必测负例

- sandbox escape、dynamic native import、超时/OOM 和取消后副作用。
- URL canonicalization、DNS rebinding、每跳 redirect 和跨 origin header/body 重放。
- allow 外请求在 transport 前零调用。
- schema 不合格输出整体失败，不进入 UI 或缓存。
