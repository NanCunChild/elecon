# ADR-029：命名 Header 与受限 Body 凭证注入

- **状态**：提议（Proposed，未授权实现）
- **日期**：2026-07-29
- **适用范围**：Broker 凭证声明、响应派生句柄、固定请求 body 汇聚点
- **触及红线**：#1、#6、#10

## 1. 背景

现有 `credentials.type: header` 固定注入 `Authorization`，声明式数据流也只能向 URL/header
汇聚。真实学校协议还存在两类无法安全表达的需求：

- 聚好联空调使用 `x-access-token`，不是 `Authorization`；
- XIDIAN 水电和图书馆需要把核心持有或响应派生的值注入固定 JSON/form body。

让 imperative adapter 读取 token、用户标识、OAuth code、NodeID 或签名后自行拼 body，会违反
红线 #1。把这些字段当普通 params 交给 UI 同样不可接受。

## 2. 提议

### 2.1 命名 Header 凭证

为 `type: "header"` 增加可选 `headerName`：

- 缺省仍为 `Authorization`，保持现有 manifest 兼容；
- 名称必须是静态、已签名 manifest 字面量；
- 禁止 `Cookie`、`Set-Cookie`、`Host`、`Content-Length`、`Connection`、代理认证头及 hop-by-hop header；
- adapter 自设同名 header 先被剥除，Broker 最后注入；
- 响应回显和日志必须按凭证值及目标 header 名脱敏。

XIDIAN 空调可预留：

```json
"aircon-session": {
  "scope": ["https://gxkt.juhaolian.cn/*"],
  "type": "header",
  "headerName": "x-access-token"
}
```

manifest 只声明引用，不包含 token 值。若 token 来自学校响应中的非标准 header/body 字段，须由 ADR-026 的 Broker 响应凭证收割与投影层写入该 ref；WebView 登录、人工导入或 mint 等其他来源仍走各自核心流程。

### 2.2 固定 Body 模板与句柄注入

声明式 `requests[]` 可增加固定 `body` 模板及 `contentType`，`inject.at` 增加 `body`，但必须满足：

- body 形状、字段名、method 和 URL 均来自已签名 manifest；
- 仅允许 JSON object 或 `application/x-www-form-urlencoded` 的具名字段；
- 值只能来自已校验 params、非秘密文本或核心不透明句柄；
- 注入前 adapter 不可读取句柄值，注入后完整 body 不回交 adapter或日志；
- 凭证字段禁止被 adapter 覆盖、删除或改名；
- body 大小、字段数和字符串长度有静态及运行时上限；
- 每次 redirect hop 重新执行 scope 与 credential permission 检查。

### 2.3 XIDIAN 水电所需附加能力

水电链还需要把 OAuth `code`、用户标识、`NodeID`、timestamp/signature 建模为核心句柄，并复用
ADR-028 的 `aes-cbc`/`base64`。其中固定 AES key 是否属于公开协议常量必须人工确认；未确认前不得写入
manifest。动态表具列表若要求依值循环，需另行决定“受限 declarative map”或“核心 action plan”，不能把
句柄解引用开放给 imperative adapter。

## 3. 校验器与兼容

- 新字段均为可选，旧 manifest 语义不变；
- validator 增加 header denylist、body 类型闭合、字段冲突、句柄类型和资源限额检查；
- Dart/TS Broker 必须共享 golden，逐字验证编码、覆盖、脱敏和失败语义；
- 未识别 `headerName`/body 注入的新客户端必须由 host/version gate 拒载相关 capability，不能静默降级。

## 4. 未决事项

1. `x-access-token` 的上游来源流程：WebView、扫码绑定还是其他学校流程；一旦值出现在网络响应中，按 ADR-026 收割，不由 adapter 读取。
2. 用户标识是否建模为 credential，还是登录身份句柄的独立类型。
3. 动态表具循环的最小非图灵完备表达。
4. body 注入与 actuator 请求的组合门禁；物理副作用另见 ADR-030。

在上述事项经人工评审前，本 ADR 不授权修改 contract、Broker 或正式 adapter manifest。
