# ADR-022：抹除 fetch/parser 模式，改用每 capability 的 `requestGraph`（声明式 / 命令式）

- **状态**：**已接受（Accepted）** · 2026-07-23 owner 评审通过（决策面锁定；§6 开放问题已于同日勾决）。本 ADR 触碰红线 #1（凭证）、#5（adapter 能力面）、#6（契约承重墙）、#10（架构性改动先 ADR）。按 [AGENTS.md](../../AGENTS.md) §1：**runtime（两端 ctx 分派 / broker 凭证注入触发条件）与 validator 的实现和测试须人工主导 + 安全清单 + ≥1 人工审，AI 不得独自闭环**。本文只固定契约面决策与迁移规格，安全落地不在 AI 闭环内。
- **日期**：2026-07-23
- **依赖**：
  - [`adr_000_abstract.md`](./adr_000_abstract.md)（§3.1 adapter 两个轴 / 分工线；§3.3 凭证边界）
  - [`adr_001_contract.md`](./adr_001_contract.md)（§5 manifest、§6 两种调用模式——本文**取代** `mode` 概念）
  - [`adr_002_trust_model.md`](./adr_002_trust_model.md)（§2.1 能力分档、§2.6 `ctx.fetch` 档位闸门——本文改其**触发条件**，不改其**保证**）
  - [`adr_009_fetch_credential.md`](./adr_009_fetch_credential.md)（broker 凭证注入 / 脱敏——机制不变，仅术语从「fetch 模式」重述为「命令式 requestGraph」）
- **被依赖**：所有现存 adapter 的 manifest（迁移见 [`docs/reference/requestgraph_migration.md`](../reference/requestgraph_migration.md)）；`contract/manifest.schema.json`、`contract/adapter-sdk/types.d.ts`、`tools/src/validator`、两端 runtime；[`adr_023`](./adr_023_declarative_dataflow.md)（声明式数据流扩展，建在本文 `declarative` 轴上，将命令式收窄到罕见——见 §2.5）。
- **适用范围**：adapter 声明「取数请求由谁编排」的契约面，以及该声明如何被信任模型裁定。**不含**：broker 的凭证注入/脱敏机制本身（ADR-009，不变）、签名/分发（ADR-002/018，不变）。

---

## 1. 背景（Context）

ADR-001 §6 把 adapter 的调用分成两种**模式**：`fetch`（adapter 用 `ctx.fetch` 自取）与 `parser`（宿主据 manifest `requests[]` 代取、adapter 纯解析）。这个二分在命名与心智上都**误导**：

- **命名骗人**：`fetch` / `parser` 暗示「一个发请求、一个不发」。但**两种模式里真正发请求、注入凭证的都是核心的 broker**。代码实证——`client/lib/core/declarative_host.dart` 的宿主代取本身就是调 `proxyFetch`（broker）并按 scope 注入凭证，与 imperative 模式**同一套 broker、同一套注入、同一套脱敏**。declarative 模式的 adapter「无网络」，但它消费的数据**同样来自带凭证的请求**。
- **真实差别只有一个**：**请求图由谁编排**——
  - **声明式**（今 `parser`）：请求形状**静态声明**在 manifest `requests[]`，核心跑之前即可枚举、可人工/工具审计；adapter 是同步纯函数。
  - **命令式**（今 `fetch`）：请求编排在 **adapter 代码**里（`ctx.fetch` 驱动，可循环、可依响应决定下一跳）；表达力强，但请求图运行时生成、无法静态枚举。

**安全属性两者相同**（凭证不进 adapter、白名单 fail-closed、scope 限制——broker 在两种模式都强制，见 ADR-009 §2.3 / ADR-002 §2.6）。命令式相对声明式**只多出一项**：**请求图不可静态审计**。这是一项比红线**弱一档**的属性（红线守的是凭证/网络/scope 的**机制**约束，两种编排方式都满足）。

于是「`fetch` vs `parser`」是个**错误的轴**：它把「谁编排请求」这一真实区别，包装成了「碰不碰网络」的假象。

**但要进一步澄清（2026-07-23 owner 决策）：requestGraph 不是一个独立的信任档 / 分级轴。** 声明式相对命令式有**两个**不同的好处，必须分开看：

1. **可审计性**（请求图静态可枚举）：这一项**很大程度可由回放夹具近似**（如 `school-xjt` 的 `imperative.replay.json`——观测「这次跑了哪些请求」）。但夹具给的是**经验行为**而非**可证明上界**（数据依赖分支下不确定性较大）。因此可审计性**不足以**支撑一个严格分级。
2. **能力面**（声明式 adapter 手里**根本没有 `ctx.fetch`**，是纯函数）：这一项**夹具抹不平**。它是纵深防御上的能力差——纯解析器即便 broker 有 bug 也发不出任何请求；命令式的受限**依赖 broker 无 bug**。

所以真正的分级轴仍是 **trust tier（official / sideload）**；**requestGraph 只是被 trust tier 约束、并对 official 构成安全推荐的能力面**（见 §2.3）。方向是 **trust tier 约束 requestGraph，而非 requestGraph 定义 trust**。

---

## 2. 决策（Decision，草案）

### 2.1 删除 `mode`，引入每 capability 的 `requestGraph`

- **删除** manifest 顶层 `mode: "fetch" | "parser"`（连同 `required`）。
- **新增** `capabilities[].requestGraph: "declarative" | "imperative"`（**per-capability**，非 per-adapter；**required，不设默认**——见 §6）：
  - `declarative`：请求由 manifest `requests[]` 静态声明，核心代取 → 交 adapter 纯解析。（≡ 旧 `parser`）
  - `imperative`：adapter 代码用 `ctx.fetch` 自行编排取数。（≡ 旧 `fetch`）
- **粒度收益**：同一 adapter 可**混用**——`notice.list`（公开、静态）走 `declarative`，`grades.list`（需分页循环）走 `imperative`。约束（sideload⟹声明式，§2.3）与推荐按 **capability** 裁定，而非把整个 adapter 一刀切。这正是「用能力标签区分，而非用一个模式枚举」的落点。requestGraph 本身**不是**信任档（§2.3）。

### 2.2 `requests[]` 与 ctx 形状随 `requestGraph` 绑定

- `capabilities[].requests[]`：**仅** `declarative` capability 使用（宿主代取配方 `{key, method, url, credential?}`）。`imperative` capability **不得**声明 `requests[]`（用 `ctx.fetch`）——二者互斥，validator 强制。
- **ctx 形状按被分派 capability 的 `requestGraph` 选择**（运行时本就 per-capability 分派）：
  - `declarative` → ctx 无 `fetch`（只 `log`/`now`），handler **同步** `(ctx, params, responses) => Result`；`responses` 为宿主代取后脱敏的原始响应。async 返回值继续被拒（错误码 **`async_in_declarative`**；旧 `async_in_parser` **不保留**，见 §6）。
  - `imperative` → ctx 有 `fetch` + `setEphemeralCookie`（+ `log`/`now`），handler **异步** `(ctx, params) => Promise<Result>`。
- adapter-sdk 类型对应重命名：`CtxParser → CtxDeclarative`、`CtxFetch → CtxImperative`（语义不变，仅名对齐）。

### 2.3 requestGraph 不是信任档：对 official 是推荐，对 sideload 是红线 #5 的能力后果

**requestGraph 不创建、也不细分信任档。** 分级轴仍只有 trust tier。requestGraph 与 trust 的关系是**单向约束**：

- **对 official（推荐，非分级）**：official adapter 可自由选 `declarative` 或 `imperative`，**推荐优先声明式**——可审计 + 受信代码面更小。**仅当请求图太动态**（数据依赖链 / 未知页数分页 / 挑战应答，即 §2.5 的「离奇请求」）才用 `imperative`。选 `imperative` **不降低** official 的信任（它已签名/审阅），只是把审查成本从「读一张静态 `requests[]` 表」变成「读编排代码」。这是**工程推荐**，落在 `docs/rules/`，不是硬闸门。

- **对 sideload（硬约束，红线 #5 的落地）**：`trustTier: sideload` 的 adapter，其**每个** capability 的 `requestGraph` 必须为 `declarative`。**理由不是可审计性**（那可被夹具近似，见 §1），**而是能力面**：`imperative` 要给 adapter `ctx.fetch` + 凭证注入能力，红线 #5 明令不可信代码「无网络、无凭证」。若降级成推荐，恶意侧载 adapter 即可在运行时把用户 session 注入到它临时选择的任意校内端点；声明式下该受凭证请求集是**静态钉死、可审的**。这是纵深防御，**不可退让**。与旧「sideload 强制 parser」在约束强度上**等价**，只是表述从「模式」精确化到「能力面」并下沉到 capability 粒度。

- **dev/debug build 例外不变**（ADR-002 §2.5）：无签名侧载 adapter 仍可跑 `imperative`（强警告 + 全占用确认），该路径编译期从 release 剔除。
- **ADR-002 §2.6 的 `ctx.fetch` 档位闸门**：保证不变（非 official 永不触达凭证注入），仅**触发条件**从「fetch 模式」改为「capability 的 requestGraph=imperative」。broker 凭证注入机制（ADR-009）**一字不改**。

### 2.4 为什么不碰红线

- **红线 #1（凭证不离核心）**：两种 requestGraph 下，凭证注入都由 broker 完成、adapter 永不见值——本 ADR 不改 broker，注入面不变。
- **红线 #5（能力面越薄）**：`declarative` capability 的 adapter 仍是无网络/无凭证/无副作用的纯解析器（能力面）；`imperative` 仍 official 独占（release）。能力上限不放松，只把「按模式一刀切」换成「按 capability 精确 gate」。
- **红线 #6（契约承重墙）**：本 ADR **即**红线要求的 ADR。**破坏性变更、不留兼容字段**——理由见 §3。

### 2.5 声明式的凭证能力对等，命令式只补「离奇请求」

**声明式不是「弱一档、不能碰凭证」的模式——它的凭证能力与命令式完全对等**，唯一差别只是请求图由谁编排：

- **凭证注入**：声明式经 `requests[].credential` 引用凭证名，由 **broker 在宿主代取时注入**（ADR-001 §6.2；`client/lib/core/declarative_host.dart` 的 `proxyFetch` + fail-closed 守卫）。adapter 永不见凭证值。
- **请求 / 响应剥离（脱敏）**：交给声明式 adapter 的 `responses` 已由宿主剥除 `Set-Cookie` / `Authorization` / 重定向中间 token（ADR-001 §6.3，两种 requestGraph 通用）。
- 「把请求从 adapter 剥离进 manifest」本身即声明式的定义。

因此**优先声明式没有能力代价**——凭证注入、脱敏一样不缺。今日 `requests[]` 只是**独立请求**的声明式；它表达不了「下一跳需用上一响应里的值」的数据依赖链，故这类目前落命令式。

**但数据依赖链本身并非命令式独占（2026-07-23 决策，另见 [`adr_023`](./adr_023_declarative_dataflow.md)）。** 「取响应值 → 计算 → 注入下一请求」若是**固定拓扑 + 可枚举提取/计算**，可由 broker 中介的声明式数据流（假想变量 / 不透明句柄）吸收，adapter 全程不见值——这是 ADR-017 §2.9「adapter 描述、核心执行」的推广，归 **ADR-023** 专项落地。届时命令式将**收窄到只剩两类真正的「离奇请求」**：

- **动态拓扑**：未知总数的分页循环、依响应内容决定发不发某请求（请求图运行时才定，无法静态枚举）；
- **不可枚举计算**：反爬内联 JS 求解、浏览器指纹伪造（须执行任意计算，声明式提取器表达不了）。

XJT 那种「取挑战页 → 提 `client_id` → 拼下一跳」是**固定拓扑 + 纯提取**，属 ADR-023 可吸收范围，**不**是命令式的正当场景。本 ADR 只固定 requestGraph 轴；数据流扩展的契约面与安全承重归 ADR-023。

---

## 3. 破坏性变更策略（无兼容字段）

- **现状规模**：现存 adapter 仅项目自有（`school-xidian` / `school-xjt` / `school-helloworld` + templates + canary），无第三方消费者。
- **决策（owner）**：**直接破坏性删除 `mode`，不保留兼容字段、不做双读**——符合早期高频迭代（呼应放宽后的红线 #6：前期契约可破坏性更新，向后兼容默认豁免）。迁移由 [`requestgraph_migration.md`](../reference/requestgraph_migration.md) 驱动，owner 逐个手改 adapter manifest。
- **代价**：迁移期内旧 `mode` manifest 与新 validator/runtime 不共存；一次性切换。因规模小（6 载体、manifest-only 改动、index.js 不引用 mode）代价可控。

---

## 4. 影响面（落地清单，🔒=安全承重、人工主导）

**契约 `contract/`**（红线 #6）
- `manifest.schema.json`：删顶层 `mode`；`capabilities[]` 增 `requestGraph` 枚举（**required per capability，无 default**）；`requests[]` 描述改「声明式 capability 使用」+ 与 `imperative` 互斥约束；顶层 `required` 去掉 `mode`。
- `adapter-sdk/types.d.ts`：`CtxParser→CtxDeclarative`、`CtxFetch→CtxImperative`；handler 类型注释重述。
- `capability/registry.json`：**无需改**（与 mode 无关）。

**Runtime 🔒**（server + client）
- `server/src/runtime/sandbox.ts`：ctx 分派键从 `input.mode` → 被分派 capability 的 `requestGraph`；`buildParserCtx`≡声明式 ctx、fetch ctx≡命令式；错误码 **`async_in_parser` 删除，一律 `async_in_declarative`**（类型联合 / 诊断文案同步，不留旧别名）。
- `client/lib/core/{adapter_runtime,declarative_host,adapter_launcher,loader}.dart`：分派同步；`declarative_host` 是声明式的宿主代取路径（保留 980bfc0 的「未声明 credential 却命中注入 → fail-closed」守卫）；客户端同样只识别 `async_in_declarative`。
- ADR-002 §2.6 闸门触发条件更新（imperative → 档位校验）。

**Validator 🔒 `tools/src/validator/index.ts`**（逐条）
- `C3` sideload⟹parser → **sideload⟹每 capability 声明式**。
- `C4-a` fetch 须有 allow → **含 imperative capability 须有 allow**。
- `C4-b` parser 须有 requests⊆allow → **声明式 capability 须有 requests 且 ⊆allow**。
- `C8` parser requests.credential 闭合 → **声明式同款**。
- **新增**：`imperative` capability 不得声明 `requests[]`（互斥）。
- `C11`（体积上限）不受影响。
- schema 层：`requestGraph` **required、无 default**（缺字段 = 校验失败，不得隐式 imperative）。

**adapters/**（owner 迁移，manifest-only + template 目录）
- `school-xidian`：capability `notice.list` → `declarative`。
- `school-xjt` / `school-helloworld`：capability → `imperative`。
- **template 目录强制重命名**：`adapters/_template/{parser,fetch}` → `{declarative,imperative}`；canary 同步；全仓路径引用（README / smoke / CI）一并改。

**文档**：ADR-001 §6 重写（两种模式→请求图声明性）+ §5.1/§5.2；ADR-002 §2.1 表 / §2.6；ADR-009 术语脚注（fetch 模式→imperative requestGraph）；ADR-018 §66 表；`docs/rules/{testing,ai_coding}.md` 的「纯解析器/parser」措辞；template README。**术语迁移原则：尽量不留旧概念**（`mode` / `parser`/`fetch` 模式 / `async_in_parser` / `CtxParser` 等作为现行契约名全部替换；历史 ADR 叙述可用「旧称」一句带过）。

---

## 5. 取舍（Consequences）

**收益**
- 概念诚实：不再假装「一个发请求一个不发」；轴变成真实的「请求图声明性」。它是被 trust tier 约束的**能力面**，不是新信任档（§2.3）。
- 粒度更细：per-capability 约束，公开静态能力可声明式（sideload 可用），同 adapter 的凭证能力可命令式（official），不再整包一刀切。
- 分工明确：声明式是**默认与推荐**（凭证能力不缺，§2.5）；命令式是 official 的逃生舱，仅补数据依赖的动态请求图。

**代价 / 已知约束**
- 一次性破坏性切换，迁移期不共存（§3，规模小可控）。
- runtime/validator 属安全承重，须人工主导落地（🔒，本 ADR 不闭环）。
- ADR-009 等多篇需术语同步（机械改，不涉再决策）。

---

## 6. 开放问题（已勾决 · 2026-07-23）

1. **template 目录是否重命名**（`_template/{parser,fetch}` → `{declarative,imperative}`）？
   - **勾决：重命名。** 与 `requestGraph` 枚举对齐；README / smoke / CI / 校验示例路径同步改。非契约面，但属术语清理，与第 3 条同原则：尽量不留旧概念。
2. **`requestGraph` 是否设默认值**？
   - **勾决：不设默认、required。** 强制 adapter 作者显式声明请求图；schema 与 validator 缺字段即失败。避免「忘写 = 隐式命令式」的提权隐患。
3. **旧 `async_in_parser` 错误码**是否改为 `async_in_declarative`？
   - **勾决：改，且不留旧码。** 两端 runtime 类型联合、诊断文案、测试名一律 `async_in_declarative`；不保留别名兼容。术语迁移原则：**尽量不留下旧概念**（契约/API/错误码现行名中消除 `parser`/`fetch` 模式与 `mode`）。
