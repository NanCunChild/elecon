# ADR-023：声明式跨请求数据流（假想变量 / 不透明句柄）——把数据依赖链从命令式收回声明式

- **状态**：**已接受（Accepted）** · 2026-07-23 owner 评审通过（决策面锁定：仅交付封闭 op 词表，任意计算预设为 QJS-复用的零依赖后续升级，见 §2.4）。
  **修订 2026-07-24（owner 勾决落地决策）**：§5 原「开放问题」1–6 全部转为决策记录（提取器词表与限额、compute 词表与类型化、嵌套复杂度限额、MVP 允许凭证派生值、缺失语义 fail-closed）；§2.5 增记 MVP 凭证派生值决策与两条已接受残余风险；**§2.6 决策被推翻并改写**——`devSideload` 在 DEV 下与 official 同权（原为「带 `compute` official-only」），附 🔒 防扩散条款。**§5 第 7 项（schema `if/then`）仍开放。**
  触碰红线 #1（凭证）、#5（adapter 能力面）、#6（契约承重墙）。按 [AGENTS.md](../../AGENTS.md) §1：**数据流执行、句柄解引用、注入、脱敏、污点围栏的实现与测试须人工主导 + 安全清单 + ≥1 人工审，AI 不得独自闭环**。本文只固定契约面与执行模型决策。
- **日期**：2026-07-23
- **依赖**：
  - [`adr_022_request_graph.md`](./adr_022_request_graph.md)（`declarative` / `imperative` 轴——本文**扩** `declarative`，令数据依赖链无需命令式）
  - [`adr_017_sso_master_credential.md`](./adr_017_sso_master_credential.md)（§2.8/§2.9「adapter 描述、核心决策 + 执行」不变量 + `{{cred:…}}` 占位符 + 封闭方案枚举——本文是其 **PR-6** 挂起项的一般化）
  - [`adr_009_fetch_credential.md`](./adr_009_fetch_credential.md)（broker 注入 / 脱敏 seam——本文复用）
  - [`adr_013_manifest_credentials.md`](./adr_013_manifest_credentials.md)（`credentials` 声明）
  - [`adr_001_contract.md`](./adr_001_contract.md)（§3.4 缺失语义、§6.2 声明式代取、§6.3 凭证零泄露）
- **落地跟踪**：[`docs/reference/declarative_dataflow_migration.md`](../reference/declarative_dataflow_migration.md)（§5 开放问题勾决后方可进入契约/runtime 实现）。
- **被依赖**：`adapters/*` 迁移（命令式收窄至罕见）；`contract/manifest.schema.json`（新增 `bind`/`compute`/`inject`）；`contract/adapter-sdk/types.d.ts`；`tools/src/validator`；两端 runtime（`declarative_host.dart` / `sandbox.ts` 的代取编排）。
- **适用范围**：**声明式** capability 内「响应派生值 → 计算 → 注入下一请求」的契约面与执行模型。**不含**：命令式（ADR-022）、broker 凭证注入机制本身（ADR-009 不变）、UI。

---

## 1. 背景（Context）

ADR-022 把命令式收窄到「请求图无法静态声明」的场景。剩下的一大类是**数据依赖链**：第二个请求需要借用第一个响应里的值（如挑战页给出 `client_id`，下一跳带上它）。它今天落命令式，但**本不必**——ADR-017 §2.9 已立不变量：

> adapter 只**描述**（声明式数据、封闭词表）；**核心决策 + 执行**（持值、跑控制流、编排）。adapter 永不见值、永不执行。

ADR-017 §2.8 为「body 内嵌且被签名的票据」挂起了 **PR-6（核心侧钩子专项 ADR）**，边界圈定为「body 模板 + `{{cred:…}}` 占位符 + 封闭签名方案枚举，绝非 adapter 任意代码」。**本 ADR 是 PR-6 的一般化**：把「占位符引用**存储凭证**」推广到「引用**上一响应派生的值**」，机制同构。

---

## 2. 决策（Decision）

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

**MVP 允许凭证派生值（owner 决策，2026-07-24；对应 §5 决策 4）**：

- **MVP 不限制凭证派生值进入数据流。** 理由：驱动本 ADR 的真实场景（挑战页 → 取 `client_id` → 下一跳）中，挑战页响应本身往往就来自带 session 凭证的请求；一刀切禁掉会使 MVP 无真实用例，特性沦为空转。
- **MVP 期的实际防护强于「没有污点系统」的字面印象**，因为两条约束是**格式自带、免费成立**的：① 声明面**没有分支构造**（静态 DAG），故「`if(tainted)` 决定发不发请求」在语法上不可表达；② `inject.into/at/name` 静态声明死，故「依值选汇聚点」不可表达。MVP 真正缺的只是**污点标记与传播**本身。
- 🔒 **回显剥离是 MVP 必做项，不得延后**：broker 知道注入句柄的真实字节，须像剥 `Set-Cookie` 一样，把响应里回显的注入值剥掉再交 adapter。此项成本极低却直接堵死回读通道，是 MVP 期替代污点围栏的关键一环（落地见迁移清单 §4）。

**已接受的残余风险（owner 明示接受，2026-07-24）**：

1. **比较预言机（每次运行 1 bit）**：adapter 仍可「注入猜测值 → 观察最终产出差异」。缓解：official 人工审 + 运行由用户触发（无法高频循环）。**接受**，随污点自动围栏落地而消除。
2. **长度预言机**：单句柄 64KB 上限触发的报错，会向 adapter 泄漏「该值是否超过 64KB」。owner 明示：**为保持 adapter 的灵活度，此代价必要且接受**。注意本风险因错误只进宿主日志（§5 决策 6）而进一步收窄——adapter 观测到的是整条 capability 失败，而非某句柄的具体长度信息。

**Threat scoping（明确出范围）**：「恶意 official 作者 + 自控某白名单校内端点、读其日志」**不属本安全模型**——明文 relay 一样能泄，归 **official = 人工审 + 签名**兜，非污点职责。污点真正的活是三件：防**好心 adapter 的意外泄漏**、堵**廉价比较预言机**（对付配合但非恶意的服务器）、**让审阅可控**。

### 2.6 信任门：`devSideload` 在 DEV 下与 official 同权（2026-07-24 修订）

> **本节推翻本 ADR 初稿「带 `compute` 的数据流 official-only」的决策**（owner 2026-07-24 勾决）。初稿理由是「审计面增大，保守 official-first」；下述证据表明该保守取向在本项目的信任档结构下不产生实际收益，反而卡死 official adapter 的供给侧。

**决策：`devSideload` 档的声明式 capability 获得与 official 完全相同的 `bind`/`compute`/`inject` 能力面。**

**依据一（结构性）**：本项目信任档只有两个——`AdapterTrustTier.official` / `devSideload`（`client/lib/core/trust/trusted_context.dart`），且 `devSideload` **结构上仅 debug build 可构造**（`fetchTrustPermitted`：official 恒放行，其余仅非生产；服务端对应 `NODE_ENV !== "production"`）。叠加 ADR-024：DEPLOY profile 的侧载路径**编译期剔除**。故 **sideload 在出货产物里根本不存在**——给它 dataflow 能力**不改变终端用户面临的攻击面**，只影响开发者本机，属「本地运行了不可信代码」的既有风险，由 ADR-002 §2.5 的强警告 + 每 `adapterId` 首次确认承接。

**依据二（供给侧）**：official adapter 由社区先写出、再经审查铸造。若 sideload 不能跑 `compute`，社区开发者**无法在本地开发与调试声明式 dataflow adapter**，等于卡死 official 的上游来源。

**红线 #5 不破**：sideload adapter 仍无 `ctx.fetch`、仍不见句柄值——数据流全程由 broker 执行。本决策放宽的是**声明面的表达力**，不是 adapter 的能力/信任面。

**🔒 防扩散条款（不可省略）**：本决策**只绑定「`devSideload` 这一档结构上仅存在于 DEV 构建」这一事实**。ADR-018 正在铺第三方分发与四信任域——**若将来新增任何「在生产环境中可存在的第三方 / 非 official 档」，它不自动继承本决策**，必须就 dataflow 能力面重新裁定。实现上要求：能力判定挂 `devSideload` 档本身，不得写成「非 official 即放行」的否定式。

---

## 3. 落地性（挂现有 seam，非新造）

- 现声明式执行体已在：`client/lib/core/declarative_host.dart` `fulfillDeclarativeRequests`（逐条 `proxyFetch` → 组装 `responses` → 交 adapter）；server 侧 `sandbox.ts` 对称。
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

## 5. 决策记录（2026-07-24 owner 勾决）

> 原「开放问题」1–6 已勾决，逐条转为决策。第 7 项（schema `if/then`）仍开放。
> 落地条目见 [`declarative_dataflow_migration.md`](../reference/declarative_dataflow_migration.md) §0。

### 决策 1 · 提取器首批词表

**首批放行三个，`css-select` 不进首批。**

| `source` | `extract` | 输入上限 | 备注 |
|---|---|---|---|
| `header` | `{ "name": … }` | **4 KB** | 响应头 |
| `body` | `{ "jsonpath": … }` | **8 MB** | 对齐现有 `DEFAULT_MAX_BODY_BYTES`（`server/src/runtime/transport/direct.ts`），不新造限额 |
| `regex` | `{ "pattern": …, "group": n }` | **8 KB** | 语法受限子集 + 回溯步数预算，见下 |

- **`css-select` 明确延后**（非否决）：正常服务不会把业务核心放进 CSS 结构；且它要拉 HTML 解析器、跨端一致成本最高、DOM 内存在移动端可膨胀 10–20 倍。**标记为可扩展**，出现真实用例再按本表格式补入。
- **匹配数量 = 1**：单次提取**只返回一个标量值**；**不支持数组句柄**。这一并消除了「数组句柄如何注入」的整类设计问题。
- **`regex` 的闸门是步数不是输入大小** 🔒：输入上限挡不住灾难性回溯（`(a+)+$` 类模式在 8 KB 输入上即可挂死），而模式串由 adapter 作者提供——正是需防的一方。故采用**回溯步数预算**（超预算 → fail-closed 错误，非超时）+ **语法白名单**（首批禁嵌套量词、禁 lookbehind）。两端步数计数须一致，否则双跑 golden 漂移。

### 决策 2 · `compute` 封闭 op 词表

**首批词表**：`concat` / `substring` / `base64` / `hex` / `urlencode` / `hmac-sha256` / `hkdf` / 签名方案枚举 id（沿用 ADR-017 §2.8 形式） / **`now`**。

四条随词表一起生效的语义约束：

1. **句柄类型化（bytes / text）** 🔒：`hmac-sha256`、`hkdf` 产出**原始字节**；`concat` 混接 bytes 与 text 是未定义行为。故**句柄带类型标签**，`base64` / `hex` 是唯一的 bytes→text 通道，类型不匹配由 validator **静态**拒绝。**须配套两端类型语义测试**。
2. **确定性不变量**：**禁 `random` / `uuid`** ——否则 ADR-001 §8 双跑 golden 立即失效。**`now` 放行**，因为它由 broker 喂入定值（复用既有 `AdapterRunInput.nowMs`，现有 smoke 已用固定 `NOW`），双跑可复现。放行 `now` 是为覆盖带时间戳 / nonce 的签名流，否则该类会被无谓推回命令式。
3. **`hmac-sha256` / `hkdf` 的 key 只能是句柄引用，不得是字面量** 🔒：manifest 是**已签名并分发**的产物，写入字面量密钥等于公开。key 恒为凭证派生句柄——这与决策 4（允许凭证派生值）自洽，也正是该 op 的有用形态。
4. **跨端语义逐 op 钉死** 🔒：JS `substring` 越界**钳制**、Dart `substring` **抛异常**；`urlencode` 在两种语言里均有多个变体（component / query / RFC3986，空格编 `%20` 还是 `+`）。ADR 落地时须给出**逐 op 形式化语义表**，每 op 至少一条双端 golden。

（**任意纯计算之争已收敛入 §2.4**：封闭词表默认交付；任意计算 = 复用 QJS、零依赖，触发条件 = 举出封闭词表无法表达且非命令式的真实案例。）

### 决策 3 · 允许嵌套；复杂度限额

**允许** `compute` 嵌套 / 引用前置 `compute` 输出（以少量原语博更大覆盖）。限额如下：

| 限额 | 值 | 作用 |
|---|---|---|
| 嵌套深度 | **16** | owner 按安全取向自 32 下调 |
| **单句柄值上限** | **64 KB** | 🔒 主闸门之一 |
| **全 DAG 句柄总预算** | **4 MB** | 🔒 主闸门之一，超出 fail-closed |
| 节点数 | **64** | 深度限不住扇出宽度 |
| 每 op 参数个数 | **8** | 挡单层 `concat(a,a,…,a)` 放大 |
| 请求数 | **复用现有 `maxRequests`（默认 20）** | 不新造 |

🔒 **限额必须同时约束输出，不能只约束输入**：`concat` 可自我倍增（`c1=concat(x,x)`、`c2=concat(c1,c1)`…），仅限输入时嵌套 16 层即 **2¹⁶ 倍**放大。**真正的闸门是单句柄 64 KB + 全 DAG 4 MB**，深度与节点数是纵深，不是主防线。

### 决策 4 · MVP 允许凭证派生值

**允许**，不再进一步限定。详见 §2.5「MVP 允许凭证派生值」及其中的 🔒 回显剥离必做项与两条已接受残余风险。

### 决策 5 · `devSideload` 在 DEV 下与 official 同权

**同权**。本决策**推翻本 ADR 初稿 §2.6 的 official-only**，完整依据、红线论证与 🔒 防扩散条款见改写后的 §2.6。

### 决策 6 · 缺失语义：统一 fail-closed

**句柄提取失败、匹配失败、注入时句柄缺失——一律 fail-closed，整条 capability 失败。不提供「缺失即省略下游注入」。**

三条理由：

1. **原表述「呼应 §3.4」是串台，已撤销**：ADR-001 §3.4 的「缺失语义」管的是 **adapter emit 给 UI 的数据字段**（字段缺失 = 该校不提供该信息），与「要不要发出一个缺了签名的 HTTP 请求」不是一回事，不能用来支撑省略注入。
2. **省略本身是泄漏位**：「值在 → 带参数；值不在 → 不带」让**请求形状随数据存在与否而变**，是 §2.5 约束 2「依值影响请求」的弱化形式；配合的服务器可在每个注入点观测到 1 bit。与决策 4（允许凭证派生值）叠加会放大预言机面。
3. **语义后果不对称**：若缺的是签名 / token，静默省略 = **发出一个未认证的请求**，可能被对端记日志、或以降级权限成功——比干脆失败更糟且更难察觉。

🔒 **错误只进宿主日志 / 面向用户的诊断，绝不回流 adapter**：若 adapter 能观测到「某句柄提取失败」，那本身就是一条回读通道（可探测值的存在性与形状）。adapter 侧看到的必须是整条 capability 失败，与正常失败路径**不可区分**。

### 7 · 仍开放：schema 层是否新增 `if/then`

**未勾决。** 建议：**保持 schema 不加 `if/then`，`bind`/`compute`/`inject` 的组合约束全部由 validator 承担**——与 ADR-022 先例一致（`requestGraph`/`requests` 互斥走 validator C12 而非 schema），且本 ADR 的约束（引用闭合、DAG 无环、类型匹配、汇聚点静态、复杂度限额）**本质超出 JSON Schema 表达力**，硬塞 `if/then` 只能覆盖皮毛却制造两套真相。
