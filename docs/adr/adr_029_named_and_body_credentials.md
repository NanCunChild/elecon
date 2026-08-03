# ADR-029：命名 Header 与受限 Body 凭证注入

- **状态**：已接受 （2026-07-31）
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
- **且禁止落在响应头 allowlist 上**（`Content-Type`/`Content-Encoding`/`Date`/`Cache-Control`/`ETag`/`Last-Modified` 等，ADR-009 §2.5）：命名凭证头若与响应 allowlist 同名，上游一旦把该值回显在同名响应头上，`sanitizeResponseHeaders` 会当合法头保留 → 凭证直达 adapter（破红线 #1）。禁其重叠使「回显必被丢弃」成为**结构保证**而非巧合；
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

### 3.1 落地状态（2026-07-31）

- **§2.1 命名 header 契约 + validator：已落地**。manifest schema `credentials.<ref>.headerName`（可选、静态 token pattern `^[A-Za-z][A-Za-z0-9-]*$`）；validator `CH1`（仅 type=header 可声明）/ `CH2`（token 合法性）/ `CH3`（denylist：Cookie/Set-Cookie/Host/Content-Length/Connection/代理认证/hop-by-hop，**并含响应头 allowlist 全部名** Content-Type/Content-Encoding/Date/Cache-Control/ETag/Last-Modified——见下「回显剥离」；Authorization 作缺省不入 denylist）。denylist 与运行时 `RESPONSE_HEADER_ALLOWLIST` **同源于 `@elecon/broker-primitives`**，防两表漂移。smoke 覆盖 CH1/CH3 负例（含响应 allowlist 名）+ `x-access-token` 正例，全绿。旧 manifest 无 headerName 语义不变（缺省 Authorization）。
- **§2.1 Broker 命名头注入：已落地（🔒 红线 #1，owner 已逐行审 + 签收 2026-08-03）**。含 CH3 扩展（headerName 禁落响应 allowlist，回显剥离成结构保证；见下）。
  - `inject-policy`（两端）：`InjectionDecision.inject` 携带 `headerName`；`decideInjection` 从 decl 透传，且**运行期纵深防御**——`headerName` 出现在非 header 声明上 → `reject(invalid_credential_decl)`（不信任 validator CH1 已拦）。
  - `assemble`（两端）：注入头名 = `decision.headerName ?? "Authorization"`；注入前按名（**大小写不敏感**）剥除 adapter 自设同名头，再写 broker 值——即便头名恰落在请求 allowlist 内也不残留 adapter 值 / 不产生同名双键。自定义头（如 `x-access-token`）本就被请求 allowlist 丢弃，此为叠加防御。
  - **响应回显脱敏是结构保证**：validator CH3 禁止命名凭证头落在响应 allowlist 上（denylist 与 `RESPONSE_HEADER_ALLOWLIST` 同源），故命名凭证头**必然**不在 `sanitizeResponseHeaders` 保留集内，回显必被丢弃——非「所选名恰好不在 allowlist」的巧合。golden `strips_named_credential_header_echo` 钉死。
  - 双端 golden：inject-policy（命名头透传 + 错配 fail-closed）、assemble（命名头注入 / adapter 同名头不残留 / allowlist 碰撞大小写剥除 / 响应回显脱敏），TS + Dart 双跑全绿。
- **§2.2 固定 body 模板注入：契约未落**，随水电链推进（§4 item 3/4 处置）；本轮只落 §2.1 header。

## 4. 未决事项

> **授权门已解除（2026-07-31 owner 评审）**：下列四项经人工评审，**§4 对 contract / Broker / 正式 adapter manifest 的授权 hold 整体解除**，ADR-029 进入分片落地（先契约 + validator，再 Broker 注入接线，后者单独人审 PR）。各项处置记录如下，仍受各自红线与后续 ADR 约束：

1. `x-access-token` 的上游来源流程：WebView、扫码绑定还是其他学校流程 —— **处置**：一旦值出现在网络响应中，按 ADR-026 收割写入 credential ref，不由 adapter 读取；WebView / 人工导入 / mint 等其他来源走各自核心流程。不阻塞 §2.1 `headerName` 契约。
2. 用户标识是否建模为 credential，还是登录身份句柄的独立类型 —— **处置**：不在本 ADR 首期强定；水电链落地时按 §2.3 建模为核心句柄（非 imperative 可解引用），需要跨执行保存再另评 credential 化。
3. 动态表具循环的最小非图灵完备表达 —— **处置**：暂不开放 imperative 句柄解引用；「受限 declarative map」vs「核心 action plan」的取舍随水电链实现另行拍板，不阻塞 header / 固定 body 注入契约。
4. body 注入与 actuator 请求的组合门禁 —— **处置**：物理副作用门禁以 ADR-030 为准；body 注入契约（§2.2）先落，与 actuator 组合的门禁在 ADR-030 接线时校验，不放宽 §2.2 的静态形状 / 大小 / 覆盖约束。

固定 AES key 是否属公开协议常量（§2.3）仍须逐案人工确认，未确认前不写入 manifest——此为**逐案数据门**，非 §4 的整体授权门，已随上文解除。
