# ADR-023：声明式跨请求数据流（假想变量 / 不透明句柄）——把数据依赖链从命令式收回声明式

- **状态**：**已接受（Accepted）** · 2026-07-23 owner 评审通过（决策面锁定：仅交付封闭 op 词表，任意计算预设为 QJS-复用的零依赖后续升级，见 §2.4；开放问题见 §5）。触碰红线 #1（凭证）、#5（adapter 能力面）、#6（契约承重墙）。按 [AGENTS.md](../../AGENTS.md) §1：**数据流执行、句柄解引用、注入、脱敏、污点围栏的实现与测试须人工主导 + 安全清单 + ≥1 人工审，AI 不得独自闭环**。本文只固定契约面与执行模型决策。
- **日期**：2026-07-23
- **依赖**：
  - [`adr_022_request_graph.md`](./adr_022_request_graph.md)（`declarative` / `imperative` 轴——本文**扩** `declarative`，令数据依赖链无需命令式）
  - [`adr_017_sso_master_credential.md`](./adr_017_sso_master_credential.md)（§2.8/§2.9「adapter 描述、核心决策 + 执行」不变量 + `{{cred:…}}` 占位符 + 封闭方案枚举——本文是其 **PR-6** 挂起项的一般化）
  - [`adr_009_fetch_credential.md`](./adr_009_fetch_credential.md)（broker 注入 / 脱敏 seam——本文复用）
  - [`adr_013_manifest_credentials.md`](./adr_013_manifest_credentials.md)（`credentials` 声明）
  - [`adr_001_contract.md`](./adr_001_contract.md)（§3.4 缺失语义、§6.2 声明式代取、§6.3 凭证零泄露）
- **被依赖**：`adapters/*` 迁移（命令式收窄至罕见）；`contract/manifest.schema.json`（新增 `bind`/`compute`/`inject`）；`contract/adapter-sdk/types.d.ts`；`tools/src/validator`；两端 runtime（`parser_host.dart` / `sandbox.ts` 的代取编排）。
- **适用范围**：**声明式** capability 内「响应派生值 → 计算 → 注入下一请求」的契约面与执行模型。**不含**：命令式（ADR-022）、broker 凭证注入机制本身（ADR-009 不变）、UI。

---

## 1. 背景（Context）

ADR-022 把命令式收窄到「请求图无法静态声明」的场景。剩下的一大类是**数据依赖链**：第二个请求需要借用第一个响应里的值（如挑战页给出 `client_id`，下一跳带上它）。它今天落命令式，但**本不必**——ADR-017 §2.9 已立不变量：

> adapter 只**描述**（声明式数据、封闭词表）；**核心决策 + 执行**（持值、跑控制流、编排）。adapter 永不见值、永不执行。

ADR-017 §2.8 为「body 内嵌且被签名的票据」挂起了 **PR-6（核心侧钩子专项 ADR）**，边界圈定为「body 模板 + `{{cred:…}}` 占位符 + 封闭签名方案枚举，绝非 adapter 任意代码」。**本 ADR 是 PR-6 的一般化**：把「占位符引用**存储凭证**」推广到「引用**上一响应派生的值**」，机制同构。

---

## 2. 决策（Decision，草案）

### 2.1 假想变量 = 不透明句柄

adapter 声明一段**数据流程序**（提取 → 计算 → 注入），其中的变量是**不透明句柄**：adapter 操作的是*引用名*，**broker 是唯一能解引用（拿到字节）的一方**。adapter 全程**不见值**。这是能力安全里的 taint-carrying opaque handle，直接落 ADR-017 §2.9 不变量。

### 2.2 四段声明面（manifest，per 声明式 capability）

在 `requestGraph: "declarative"` 的 capability 下增三段（`requests` 沿用 ADR-022）：

```jsonc
"requestGraph": "declarative",
"requests": [
  { "key": "A", "method": "GET",  "url": "...", "credential": "session" },
  { "key": "B", "method": "GET",  "url": "..." },
  { "key": "C", "method": "POST", "url": ".../submit" }
],
"bind": [                                                  // 抽取：从响应取值绑为句柄
  { "var": "auth_A", "from": "A", "source": "header", "extract": { "name": "X-Auth" } },
  { "var": "auth_B", "from": "B", "source": "body",   "extract": { "jsonpath": "$.token" } }
],
"compute": [                                               // 暂存/计算：封闭 op，broker 执行
  { "var": "auth_C", "op": "concat", "args": ["auth_A", "auth_B"] }
],
"inject": [                                                // 注入：静态汇聚点
  { "var": "auth_C", "into": "C", "at": "url", "name": "sig" }
]
```

- **抽取源恒为响应**（响应头 / body），**不是请求**——broker 自拼的请求头（含它注入的凭证）不得被引用；「把某凭证也放进另一请求」只需给两请求同一 `credential` ref，不用句柄。
- `into`/`at`/`name` **静态声明死**（见 §2.5 承重墙）。

### 2.3 执行模型：固定 DAG，拓扑序（这是「有限状态」成立的形态）

数据流是**静态 DAG**（节点=请求/绑定/计算/注入，边=数据依赖），broker 拓扑排序执行：

```
R_A(cred)     R_B
  │extract      │extract
  ▼             ▼
auth_A        auth_B
  └──────┬──────┘
         ▼ compute concat  (broker 原生)
       auth_C
         ▼ inject @ R_C.url(静态)
       R_C ──► 全部响应脱敏后 ──► adapter 末尾同步解析一次
```

- 无依赖的请求（A、B）可并发；有依赖的（C）等其输入句柄就绪。
- **抽取在脱敏前**对响应求值（broker 侧）；**adapter 仍是跑一次的末端 declarative 纯解析**，不介入链路、不见句柄。
- **「有限状态」成立的两条件**：① 提取/计算词表**封闭**（无任意计算）；② 拓扑**固定**（无依值的循环/分支）。破其一即回到命令式（ADR-022 §2.5 两类）。

### 2.4 计算 = 封闭 op 词表，broker 原生执行（默认交付；任意计算预设但暂不建）

**决策（owner，2026-07-23）：本 ADR 只交付「封闭 op 词表」并尽量丰富算子；任意纯计算预设为后续升级，暂不建——待封闭词表证明不够再提。**

- **交付面（封闭词表）**：`compute[].op` 是**封闭枚举**，由 **broker 原生代码**执行，可一眼审、侧信道可控。首批词表应**尽量丰富**以吃下绝大多数「固定拓扑 + 派生值」场景（`concat` / `substring` / `base64` / `hex` / `urlencode` / `hmac-sha256` / `hkdf` / 签名方案枚举 id…，见 §5）。这已覆盖 XJT 类「提 `client_id` → 拼下一跳」等真实需求。
- **命令式仍兜「不可枚举计算」**（反爬内联 JS 求解、指纹伪造，ADR-022 §2.5）——该类几乎总同时需要动态拓扑或把值读回 adapter，本就是命令式地盘，不与本词表竞争。
- **任意纯计算（预设、暂不建）**：封闭词表表达不了任意计算。**若**将来出现封闭词表无法表达、且**不**已落命令式（非动态拓扑、值须对 adapter 不可见）的真实案例，才升级为 broker 中介的**任意纯函数** compute 节点。届时执行体决策**已定形**，评审时无引擎悬念：
  1. **复用现有 QuickJS，零新依赖**。双端本就同一个 QuickJS（服务端 `quickjs-emscripten` / 客户端 `flutter_qjs_next`，见 `server/src/runtime/sandbox.ts`、`client/lib/core/adapter_runtime.dart`），执行/内存/deadline 限额（fuel）已就位。compute 在已 barebones 的 ctx 上再删 `Date` / `Math.random` 即得 hermetic 纯函数——**复用现有双端一致性 golden**。
  2. **不走 WASM，也非「新增第二个容器」**。客户端 `flutter_qjs_next` 是 QJS-FFI 绑定、非 wasm 运行时——WASM 要在客户端引入新 native 引擎（落 OHOS 等平台矩阵）；wasm blob 对人工审是**倒退**（须另附源码 + 可复现构建才回到 JS 源码同等可审）；而 WASM 的真实优势（沙箱、fuel）QJS 已具。故复用既有 QJS，而非曾拒的「新增第二个 QuickJS 容器」。
  3. **修正旧述「任意 JS 退回命令式」**：hermetic 纯函数（无 fetch/时钟/RNG）审计面**严格小于**命令式（后者能发请求、循环、依响应定拓扑），落在封闭词表与命令式**之间**，非一路退回。其真正门槛不在引擎，而在 §2.5 的**污点围栏**（引擎无关）。
- **零后悔**：任意计算路线零依赖、复用现有引擎与 golden，故现在只交付封闭词表**不锁死任何东西**；触发时加一个 QJS compute 节点无需新基础设施。

### 2.5 安全承重墙：污点三约束（MVP 后补，但静态汇聚点即刻生效）

**「adapter 看不到值」是必要不充分**——adapter 控制数据流程序，若能对秘密值运算并观测到依赖结果的效果，就能一位位套出值（预言机 / 侧信道），全程不看内容。真正的闸门是三条：

1. **污点标记**：从「带凭证请求的响应」或凭证派生的句柄 = **tainted**。
2. **tainted 只能流向静态注入汇聚点**：`inject` 的目标 request + 位置静态声明死，**绝不依值选择注入到哪**。
3. **禁分支 / 禁回读**：不得 `if(tainted)` 决定发不发请求；tainted 或其任何布尔函数不得进入 adapter 解析输出。
   - 白送闸门：broker 知道注入句柄的真实字节，可像剥 `Set-Cookie` 一样**把响应里回显的注入值剥掉**再交 adapter（堵回读）。

**分期（owner 决策，2026-07-23）**：
- **静态汇聚点是格式自带的**（`inject.into/at` 本就静态），**非污点系统**——故 MVP 天然无「依值选汇聚点」这条侧信道。
- **MVP 先不上污点标记 + 禁分支/禁回读的自动围栏**；此期**替代闸门 = official 人工审**（数据流声明式、可一眼审，确认无预言机/怪汇聚点）。
- **污点自动围栏的加入触发点 = 不再逐条亲审**（引入其他 official 贡献者 / adapter 数量上规模），而非「发版前」教条。

**Threat scoping（明确出范围）**：「恶意 official 作者 + 自控某白名单校内端点、读其日志」**不属本安全模型**——明文 relay 一样能泄，归 **official = 人工审 + 签名**兜，非污点职责。污点真正的活是三件：防**好心 adapter 的意外泄漏**、堵**廉价比较预言机**（对付配合但非恶意的服务器）、**让审阅可控**。

### 2.6 信任门：带计算的数据流 official-only

- **带 `compute` 的数据流 official-only**（ADR-017 §2.9：能力增长在 official 封闭词表，不放宽侧载）。
- **sideload 顶多**给最朴素的 `bind → inject 到固定位置、零 `compute``；带计算/多跳数据流不给（或整体不给，见 §5 开放问题）。红线 #5 能力面：sideload adapter 仍无 `ctx.fetch`、不见值——数据流由 broker 执行，能力红线技术上不破，但审计面增大，故保守 official-first。

---

## 3. 落地性（挂现有 seam，非新造）

- 现声明式执行体已在：`client/lib/core/parser_host.dart` `fulfillParserRequests`（逐条 `proxyFetch` → 组装 `responses` → 交 adapter）；server 侧 `sandbox.ts` 对称。
- 增量：① 解析 `bind`/`compute`/`inject`；② 代取从**平铺**改**依赖拓扑序**（静态 DAG，一次拓扑排序）；③ 抽取（脱敏前）→ broker 侧 phantom map；④ `compute` 原生执行；⑤ 注入**复用凭证注入 seam**；⑥ 脱敏剥注入值 + `Set-Cookie`/token。
- **唯一结构性改动 = 平铺 → 拓扑序**。**两端双跑一致**（ADR-001 §8 golden）。

---

## 4. 取舍（Consequences）

**收益**
- 命令式收窄至罕见（仅动态拓扑 + 不可枚举计算，ADR-022 §2.5）；数据依赖链回归声明式、可审、可热替换。
- **比命令式更安全**：中间值由 broker 提取，**从不进 adapter 代码**（命令式下 adapter 要读 body 才拿到中间 token）。

**代价 / 已知约束**
- 代取编排从平铺改拓扑序（两端一致，🔒）。
- 污点自动围栏后补，MVP 期依赖 official 人工审（§2.5）。
- 新增 `bind`/`compute`/`inject` 契约面 + validator 规则（scope/汇聚点/词表闭合）；封闭 op 词表须跨端一致实现（Dart/TS golden）。

---

## 5. 开放问题（待评审勾决）

1. **提取器词表**首批集合：`header(name)` / `body(jsonpath)` / `regex(group)` / `css-select`？（须封闭、无任意计算）
2. **`compute` 封闭 op 词表终定**（A 交付面）：应尽量丰富以最大化覆盖——`concat` / `substring` / `base64` / `hex` / `urlencode` / `hmac-sha256` / `hkdf` / …；签名方案沿用 ADR-017 §2.8 封闭枚举 id 形式。是否允许 op **任意嵌套组合**（combinator，一次 `compute` 引用另一 `compute` 的输出）以少量原语博更大覆盖？（**任意纯计算之争已收敛入 §2.4**：封闭词表默认交付，任意计算 = 复用 QJS、零依赖、触发 = 举出封闭词表无法表达且非命令式的真实案例。）
3. **MVP 是否进一步限定**：MVP 阶段只允许对**非凭证派生**值做数据流（再降一层风险），凭证派生值等污点围栏到位后再开？
4. **sideload 给不给零计算 `bind→inject`**，还是整体 official-only？
5. **`compute` 的错误语义**：某句柄提取失败（源字段缺失，呼应 §3.4）时，是 fail-closed 整条能力失败，还是可声明「缺失即省略下游注入」？
