# 迁移大清单：`mode` → 每 capability 的 `requestGraph`

> 落 [ADR-022](../adr/adr_022_request_graph.md)。**破坏性、无兼容字段、一次性切换。**
>
> 🔒 = 安全承重（runtime / validator），须人工主导 + 安全清单 + ≥1 人工审（AGENTS.md §1），不得 AI 独自闭环。
>
> **建议 PR 切法（可合并为更少 PR，但顺序不可颠倒）：**
> 1. 契约 + SDK 类型（本清单 §1）
> 2. Validator + 测试🔒（§2）
> 3. Server runtime🔒（§3）
> 4. Client runtime🔒（§4）
> 5. adapters + 模板目录重命名（§5）
> 6. 文档术语同步（§6）
> 7. 全仓收尾校验（§7）
>
> 同一 monorepo 内也可单 PR 落地，但 §2–§4 必须同一 PR 内自洽（契约变了旧 runtime 立刻挂）。

---

## 0. 旧→新映射（心智锚）

| 旧 | 新 | ctx | handler |
|---|---|---|---|
| `mode: "parser"` | capability `requestGraph: "declarative"` | 无 fetch（`log`/`now`） | 同步 `(ctx, params, responses) => Result` |
| `mode: "fetch"` | capability `requestGraph: "imperative"` | `fetch` + `setEphemeralCookie` + `log`/`now` | 异步 `(ctx, params) => Promise<Result>` |

**不变量（迁移不得破坏）：**

1. 凭证永不进 adapter；broker 注入 / 脱敏路径不变。
2. release 下 sideload：**每个** capability 必须 `declarative`（原 C3 语义升级为 per-cap）。
3. declarative 必须有 `requests[]`；imperative **禁止** `requests[]`。
4. 错误码 `async_in_parser` **删除**，改为 `async_in_declarative`（不留别名）。
5. `requestGraph` **required、无 schema default**（缺字段=校验失败）。

**客户端现状坑（本迁移一并纠正）：**  
`client/lib/core/adapter_launcher.dart` 的 `_runtimeMode` 读的是 `manifest.runtime.mode`，而契约/真实 manifest 的 `mode` 在**顶层**。迁移后分派键改为 **被调用 capability 的 `requestGraph`**，勿再读顶层/runtime `mode`。

---

## 1. 契约 `contract/`

### 1.1 `contract/manifest.schema.json`

- [x] 顶层 `required` 数组：**删除** `"mode"`。
- [x] **删除** `properties.mode`（整个对象）。
- [x] `properties.capabilities.items.required`：现 `["id","emits"]` → **增** `"requestGraph"` → `["id","emits","requestGraph"]`。
- [x] `properties.capabilities.items.properties` **增**：
  ```json
  "requestGraph": {
    "type": "string",
    "enum": ["declarative", "imperative"],
    "description": "取数请求图声明性（ADR-022）。declarative=manifest requests[] 静态声明、核心代取、adapter 纯解析同步；imperative=adapter 代码 ctx.fetch 自取异步。信任门：release 下 sideload 的每个 capability 须 declarative。**required、无 default**（缺字段=校验失败，避免隐式命令式提权）。"
  }
  ```
- [x] ⚠️ **禁止**给 `requestGraph` 设 `default`。
- [x] `requests.description` 改：`"仅 declarative requestGraph 使用，声明核心代取的请求配方；imperative capability 不得声明"`。
- [ ] （可选 schema 层）`if/then`：`requestGraph==imperative` ⇒ 不得有 `requests`；或完全交给 validator C12。
- [x] 扫 schema 描述文案中的「parser 模式 / fetch 模式」→ declarative / imperative（如 `credentials` 描述 L121）。

### 1.2 `contract/adapter-sdk/types.d.ts`

| 旧符号 | 新符号 | 内容 |
|---|---|---|
| `CtxParser` | `CtxDeclarative` | 不变（log/now） |
| `CtxFetch` | `CtxImperative` | 不变（fetch/setEphemeralCookie/log/now） |
| `ParserCapabilityHandler` | `DeclarativeCapabilityHandler` | `(ctx, params, responses) => Result` |
| `FetchCapabilityHandler` | `ImperativeCapabilityHandler` | `(ctx, params) => Promise<Result>` |

- [x] 顶部注释：`模式由 manifest 的 mode 决定` → `请求图由每 capability 的 requestGraph 决定`。
- [x] 段注释 `// ---- fetch 模式的 ctx ----` → imperative；`// ---- parser 模式的 ctx ----` → declarative。
- [x] `CapabilityModule.capabilities` 联合类型改用新 handler 名。
- [x] **不留** `CtxParser` / `CtxFetch` 类型别名（破坏性清场，与错误码策略一致）。

### 1.3 契约其它（若有）

- [x] `contract/` 下 grep：`mode` / `parser` / `CtxParser` / `CtxFetch` — 仅保留与 HTTP method、文件扩展名无关的命中。
- [x] 若有 schema golden / 示例 manifest 在 contract 树内，同步改。

---

## 2. Validator 🔒 · `tools/src/validator/`

### 2.1 `tools/src/validator/index.ts` — 类型

- [x] `interface Manifest`：删 `mode: "fetch" | "parser"`。
- [x] `interface CapabilityDecl` 增：
  ```ts
  requestGraph: "declarative" | "imperative";
  ```
- [x] 文件头检查项注释 C3/C4/C8 全文改写（见下表）。
- [x] 示例命令路径：`_template/parser` → `_template/declarative`。

### 2.2 检查逻辑对照表

| 编号 | 旧条件 / code | 新条件 / code | 说明 |
|---|---|---|---|
| **C3** | `trustTier==sideload && mode!="parser"` / `C3_sideload_must_parser` | `trustTier==sideload` 且 **任一** cap `requestGraph!="declarative"` / **`C3_sideload_must_declarative`** | 红线 #5；message 列出违规 cap id |
| **C4-a** | `mode=="fetch" && allow.length==0` / `C4_fetch_empty_allow` | **存在** cap `requestGraph=="imperative"` 且 `allow.length==0` / **`C4_imperative_empty_allow`** | 无 allow 则 imperative 无处可请求 |
| **C4-b** | `mode=="parser"` 整 manifest 扫 requests / `C4_parser_no_requests` | **仅** `requestGraph=="declarative"` 的 cap：无 `requests` 或 empty → **`C4_declarative_no_requests`**；url ⊆ allow 逻辑保留 | 原 C4 白名单覆盖不变 |
| **C8** | `mode=="parser"` 时 credential 引用闭合 + unused warn | **仅 declarative cap 集合** 的 `requests.credential` | unused warn 文案去掉「parser 模式」 |
| **C12 新** | — | `requestGraph=="imperative"` 且声明了 `requests`（含 empty 数组？→ 建议有字段即拒） / **`C12_imperative_with_requests`** | 互斥 |
| **C11** | 体积上限 | **不动** | |
| **C5/C6/C7/C9/L*/M*** | 不依赖 mode | **不动**（除非 fixture 路径） | |

实现提示（C3 伪代码）：

```ts
if (manifest.trustTier === "sideload") {
  for (const cap of manifest.capabilities) {
    if (cap.requestGraph !== "declarative") {
      findings.push({
        level: "error",
        code: "C3_sideload_must_declarative",
        message: `sideload 的 capability '${cap.id}' 必须 requestGraph=declarative，当前=${cap.requestGraph}`,
      });
    }
  }
}
```

C8 签名：`Pick<Manifest, "credentials" | "mode" | "capabilities">` → 去掉 `mode`，按 cap.requestGraph 过滤。

### 2.3 `tools/src/validator/validator.smoke.ts` 🔒

现有用例全部带 `mode`；须改为 cap 级 `requestGraph`。建议用例矩阵：

| # | 场景 | 期望 |
|---|---|---|
| 1 | sideload + 任一 cap imperative | `C3_sideload_must_declarative` |
| 2 | official + 全 imperative + empty allow | C4 empty allow |
| 3 | declarative request 越出 allow | C4 url 越界 |
| 4 | 合法 declarative（占位符 URL） | 无 error |
| 5–20 | 原 credentials/login/sso 用例 | 按 cap 补 `requestGraph`（原 fetch→imperative，parser→declarative） |
| **新** | declarative 无 requests | `C4_declarative_no_requests` |
| **新** | imperative + requests[] | `C12_imperative_with_requests` |
| **新** | **混用 adapter**：capA declarative+requests，capB imperative 无 requests，official | **通过**（ADR-022 核心动机） |
| **新** | sideload 混用（含 imperative） | C3 拒绝 |
| **删** | 对顶层 `mode` 的任何断言 | |

🔒 安全相关负例（C3/C12）须人工编写或实质审阅。

### 2.4 其它 tools 引用

- [x] `tools/src/schema/schema-golden.smoke.ts`：路径 `adapters/_template/parser` → `declarative`。
- [x] `tools/` 全树 grep：`mode:` / `_template/parser` / `_template/fetch` / `C3_sideload_must_parser` / `C4_parser_no_requests`。
- [x] 校验通过命令示例与 `package.json` scripts 注释（若有）。

---

## 3. Server runtime 🔒 · `server/src/runtime/`

### 3.1 分派模型

服务端当前是**两个独立入口**（无顶层 mode 字段）：

| 函数 | 旧语义 | 新语义 |
|---|---|---|
| `runAdapter` | parser | **declarative**（可改名 `runDeclarativeAdapter`，或保留名 + 注释改） |
| `runFetchAdapter` | fetch | **imperative**（可改名 `runImperativeAdapter`） |

调用方（replay smoke、各 school smoke）按 fixture/manifest 的 **该 capability 的 requestGraph** 选入口——与客户端一致。

- [x] `AdapterRunInput`：若后续统一入口，增 `requestGraph`；若保持双入口，注释写清「由调用方按 capability.requestGraph 选择」。
- [x] **不**在 sandbox 内读完整 manifest 亦可：调用方已知道图类型。

### 3.2 `server/src/runtime/sandbox.ts`

- [x] `buildParserCtx` → 可重命名 `buildDeclarativeCtx`（或保留函数名、注释改 declarative）。
- [x] `buildFetchCtx` → 可重命名 `buildImperativeCtx`（同策略）。
- [x] 错误码：**`async_in_parser` → `async_in_declarative`**（删除旧码，不留别名）。
- [x] 错误文案：`parser capability…` → `declarative capability…`。
- [x] 段注释 `// Parser mode` / `// Fetch mode` → Declarative / Imperative requestGraph。
- [x] `fetchTrustPermitted` 闸门触发条件：仍挂在 **imperative 入口**（保证：非 official 永不触达注入）。🔒 语义不变。

### 3.3 `server/src/runtime/sandbox-qjs-util.ts`

- [x] `SandboxErrorReason` 联合类型：`"async_in_parser"` → `"async_in_declarative"`。
- [x] 注释中的 parser/fetch 措辞。

### 3.4 Smoke / testutils 路径与命名

| 文件 | 改动 |
|---|---|
| `sandbox.smoke.ts` | `_template/parser` → `_template/declarative`；`_canary/parser` → `_canary/declarative`（若改名） |
| `parser-replay.smoke.ts` → `declarative-replay.smoke.ts` | 路径 + 日志 + `replayDeclarativeFixture` |
| `__testutils__/parser-replay.ts` → `declarative-replay.ts` | 注释术语；API rename |
| `__testutils__/fetch-replay.ts` → `imperative-replay.ts` | 路径 + 注释 + `replayImperativeFixture` |
| `sandbox.fetch.smoke.ts` | 注释「fetch 模式」→ imperative；**信任闸门用例保留** |
| 各 `adapters-*.fetch.smoke.ts` | 仅注释/术语；manifest 由 §5 改 |

### 3.5 `trusted-context.ts` / broker

- [x] 注释「fetch 模式整体 fail-closed」→「imperative requestGraph 入场 fail-closed」。
- [x] **逻辑不改**（仍 `fetchTrustPermitted`）。

---

## 4. Client runtime 🔒 · `client/lib/core/` + tests

### 4.1 `adapter_launcher.dart`（part of adapter_runtime）🔒

核心分派从 **manifest 级 mode** 改为 **capability 级 requestGraph**：

- [x] `LaunchPlan.mode: String` → 删除。
- [x] 增 `LaunchPlan.capabilityRequestGraphs: Map<String, String>`  
  （或 `Map<String, RequestGraph>` enum：`declarative` / `imperative`）。
- [x] 增保留 `capabilityRequests`（仅 declarative 有非空列表）。
- [x] `planLaunch`：解析每个 cap 的 `requestGraph`（**缺字段 / 非法值 → fail-closed**，与 schema 一致，禁止 default 提权）。
- [x] **删除** `_runtimeMode`（及对 `runtime.mode` 的读取）。
- [x] `runLoadedAdapter`：
  ```dart
  final rg = plan.capabilityRequestGraphs[capability];
  if (rg == null) throw AdapterLaunchException('capability 缺 requestGraph…');
  if (rg == 'declarative') {
    // fulfillDeclarativeRequests + runDeclarativeAdapter
  } else if (rg == 'imperative') {
    // _runImperativeAdapter
  } else {
    throw … // fail-closed
  }
  ```
- [x] 混用 adapter：同一 `LaunchPlan` 可同时含两种 graph；**按本次 capability 分派**。

### 4.2 `adapter_runtime.dart` 🔒

| 项 | 动作 |
|---|---|
| `AdapterFailureReason.asyncInParser` | → `asyncInDeclarative`（或保留枚举名仅改 wire string——**wire 必须 `async_in_declarative`**） |
| bootstrap outcome `"async_in_parser"` | → `"async_in_declarative"` |
| `case 'async_in_parser':` | → `async_in_declarative` |
| `runParserAdapter` | 可 rename `runDeclarativeAdapter`；至少注释改为 declarative |
| `_buildParserBootstrap` | 同上 |
| `runFetchAdapter` / `_runFetchAdapter` | 注释 imperative；信任闸门条件不变 |
| 文件头「parser 模式 / fetch 模式」 | 改 requestGraph 术语 |

### 4.3 `parser_host.dart` → `declarative_host.dart`

- [x] rename：`fulfillDeclarativeRequests` / `DeclarativeRequestDecl` / `DeclarativeHostException`。
- [x] 注释：parser → declarative；**保留** commit 980bfc0「未声明 credential 却命中注入 → fail-closed」守卫。🔒
- [x] 不改注入/代取算法。

### 4.4 `loader.dart` / 其它 core

- [x] grep `mode` / `parser` 分派：凡把顶层 mode 当执行键的，改 requestGraph。
- [x] `trusted_context` / `fetchTrustPermitted`：注释同步；逻辑不变。

### 4.5 Client 测试

| 文件 | 改动 |
|---|---|
| `client/test/dual_run_test.dart` | 路径 `_template/parser`→`declarative`；用例名/期望 `async_in_parser`→`async_in_declarative`；`runParserAdapter` 若 rename 则跟 |
| `client/test/adapter_launcher_test.dart` | `plan.mode` 断言 → `capabilityRequestGraphs[cap]`；fixture manifest 补 `requestGraph`、删 `mode`；**增混用 cap 分派用例** |
| `client/test/fetch_runtime_test.dart` → `imperative_runtime_test.dart` | 文件重命名 + 术语 |
| `client/test/adapter_service_test.dart` | 内嵌假 manifest 的 capability 补 `requestGraph`（`_mkBundle` 的 `notice.list`：原无 `mode`→缺省 fetch，故补 `imperative`）。**易漏**：不在分派单测里，只有跑完整套件才暴露 fail-closed 拒绝 |
| 其它 test 内嵌假 manifest | 全量补 `requestGraph`（`rg -l "'capabilities'" client/test` 逐一核） |

---

## 5. adapters/（manifest + 目录）

### 5.1 生产 / 模板 manifest（每文件）

| 路径 | 删 | 每 capability 增 |
|---|---|---|
| `adapters/school-xidian/manifest.json` | `"mode":"parser"` | `"requestGraph":"declarative"`（notice.list） |
| `adapters/school-xjt/manifest.json` | `"mode":"fetch"` | `"requestGraph":"imperative"`（各 cap） |
| `adapters/school-helloworld/manifest.json` | `"mode":"fetch"` | `"requestGraph":"imperative"` |
| `adapters/_template/parser/manifest.json` → 见 5.2 | mode | declarative + 文案 |
| `adapters/_template/fetch/manifest.json` → 见 5.2 | mode | imperative |
| `adapters_tests/XIDIAN/jwc/std/manifest.json` | mode | declarative |

`displayName` / README 中「parser 模式」「fetch 模式」→ declarative / imperative。

### 5.2 目录重命名（ADR-022 §6 勾决）

```
adapters/_template/parser  →  adapters/_template/declarative
adapters/_template/fetch   →  adapters/_template/imperative
adapters/_canary/parser    →  adapters/_canary/declarative   # 若保留 canary 树
```

- [x] `git mv` 保留历史。
- [x] 新目录内 `manifest.json`：`requestGraph` 显式写出；`adapterId`/`displayName` 可含 declarative/imperative。
- [x] `adapters/_template/*/README.md`：validate 路径与术语。
- [x] `adapters/README.md`：`cp -r …/_template/fetch` → `…/_template/imperative`；表格/说明同步。
- [x] `adapters/_canary/README.md`：路径与术语。

### 5.3 index.js 注释

- [x] `school-xjt/index.js`：`@param {CtxFetch}` → `{CtxImperative}`（或双写过渡——本迁移选破坏性则直接新名）。
- [x] 其它 adapter：`rg 'CtxFetch|CtxParser|mode' adapters --glob '!**/node_modules/**'` 清零。
- [x] **handler 签名与运行时约定不变**（declarative 仍同步三参；imperative 仍 async 两参）——多数 index.js **逻辑零改**。

### 5.4 全仓路径引用同步（grep 清单）

任何命中下列字串的**代码/测试/脚本**（非历史 ADR 叙述）必须更新：

```
_template/parser
_template/fetch
_canary/parser
adapters/_template/parser
adapters/_template/fetch
```

已知代码侧（文档见 §6）：

- `tools/src/validator/index.ts` 注释
- `tools/src/schema/schema-golden.smoke.ts`
- `server/src/runtime/sandbox.smoke.ts`
- `server/src/runtime/declarative-replay.smoke.ts`
- `client/test/dual_run_test.dart`
- `adapters/README.md` / template README

---

## 6. 文档（术语同步）

| 文档 | 动作 |
|---|---|
| `docs/adr/adr_001_contract.md` | ✅ §6「两种调用模式」→「请求图声明性」；§5.1 示例删 mode、cap 加 requestGraph；§5.2 信任档 |
| `docs/adr/adr_002_trust_model.md` | ✅ §2.1 能力表、§2.6 闸门：fetch 模式 → imperative requestGraph；parser ctx → declarative |
| `docs/adr/adr_009_fetch_credential.md` | ✅ 文首术语脚注 + 正文现行术语；`CtxFetch`→`CtxImperative` 叙述 |
| `docs/adr/adr_008_client_runtime.md` | ✅ `async_in_parser` → `async_in_declarative` |
| `docs/adr/adr_013_manifest_credentials.md` | ✅ 示例 mode → requestGraph |
| `docs/adr/adr_015_manifest_login.md` | ✅ 示例同步（若适用） |
| `docs/adr/adr_018_adapter_distribution.md` | ✅ 表中 parser 行 → declarative |
| `docs/adr/adr_014_client_host_fn.md` | ✅ 术语（declarative 路径并列表述） |
| `docs/rules/testing.md` | ✅ 「纯解析器 / parser」→ declarative requestGraph |
| `docs/rules/ai_coding.md` | ✅ 同上 |
| `AGENTS.md` / `README.md` / `adapters/README.md` | ✅ 红线 #5 / 信任级别用语 |
| `docs/reference/track_b_*` / `b4_*` / `b5_*` / `b6_*` / `webview_*` | ✅ 重命名 + 术语脚注（`track_b_imperative_runtime_plan` / `b6_imperative_runtime_plan`；manifest 示例去顶层 `mode`） |
| 本文件 | 完成后把各 `[ ]` 勾掉 |

**ADR 历史叙述**可保留「旧称 parser/fetch」一句；**现行契约/错误码/路径**不留旧概念（§7 grep）。

---

## 7. 收尾校验（合并前必跑）

### 7.1 命令

```bash
# validator：每个 adapter
cd tools && npm run validate -- --adapter=../adapters/school-xidian
cd tools && npm run validate -- --adapter=../adapters/school-xjt
cd tools && npm run validate -- --adapter=../adapters/school-helloworld
cd tools && npm run validate -- --adapter=../adapters/_template/declarative
cd tools && npm run validate -- --adapter=../adapters/_template/imperative
# 或全量
cd tools && npm run validate

# tools smoke（含 validator.smoke / schema-golden）
cd tools && npm test   # 以 package.json 实际脚本为准

# server smoke
cd server && npm run smoke          # 含 parser/declarative
cd server && npm run smoke:fetch    # 若存在

# client
cd client && dart test test/dual_run_test.dart test/adapter_launcher_test.dart
# + 既有 fetch_runtime 等
```

- [x] 两端 golden 双跑一致（同夹具 → 同标准 schema，ADR-001 §8）。
- [x] 混用 manifest 手工或 smoke：official 同时 declarative+imperative 两 cap 均过。

### 7.2 全仓 grep 零残留（现行代码路径）

在排除 `node_modules`、`.dart_tool`、`build`、历史日记后，下列模式在**运行时代码 / 契约 / 测试 / adapters** 中应为 **0**（或仅出现在「旧称」脚注句）：

```bash
rg -n '"mode"\s*:\s*"(parser|fetch)"' --glob '!**/node_modules/**' --glob '!**/docs/adr/**' --glob '!**/docs/reference/**'
rg -n 'async_in_parser' --glob '!**/node_modules/**' --glob '!**/docs/adr/adr_0{0..7}*' 
rg -n 'CtxParser|CtxFetch|ParserCapabilityHandler|FetchCapabilityHandler' contract/ client/ server/ tools/ adapters/
rg -n 'C3_sideload_must_parser|C4_parser_no_requests' tools/
rg -n '_template/parser|_template/fetch|_canary/parser' --glob '!**/node_modules/**' --glob '!**/docs/**'
rg -n 'manifest\.mode|plan\.mode|_runtimeMode' client/ server/ tools/
```

允许残留：

- HTTP `method`、英语单词 mode 的无关用法、`kDebugMode`、fetch API 名 `ctx.fetch`、`proxyFetch`。
- 已归档 ADR 正文中的历史设计叙述（建议加「（旧称，见 ADR-022）」）。

### 7.3 安全签收 🔒

- [x] Validator C3/C12 与 runtime 信任闸门：安全清单勾选。
- [x] Client `planLaunch` 缺 `requestGraph` fail-closed（无默认 imperative）。
- [x] 人工审 runtime + validator diff 后才 merge（AGENTS.md §1）。

---

## 8. 实施顺序 checklist（执行用）

复制到 PR 描述即可：

```
契约
- [x] manifest.schema.json：删 mode，cap 强制 requestGraph
- [x] adapter-sdk/types.d.ts：Ctx*/Handler 重命名

Validator 🔒
- [x] index.ts 类型 + C3/C4/C8/C12
- [x] validator.smoke.ts 矩阵（含混用 + sideload 负例）
- [x] schema-golden / 路径

Server 🔒
- [x] sandbox.ts + sandbox-qjs-util 错误码
- [x] smoke 路径 declarative

Client 🔒
- [x] LaunchPlan 按 capability requestGraph 分派
- [x] async_in_declarative
- [x] dual_run + launcher 测试

Adapters
- [x] 三校 + template + canary + adapters_tests manifest
- [x] git mv _template/_canary 目录
- [x] README / 注释 Ctx*

文档
- [x] adr_001/002/008/009/013/015/018 + rules

收尾
- [x] validate 全过 + grep 清场 + 安全审
```

---

## 9. 明确不改 / 勿误伤

| 项 | 原因 |
|---|---|
| broker 注入、`proxyFetch`、cookie jar、harvest | 请求图声明性与凭证路径正交 |
| `network.allow` / `credentials` / `login` / `ssoMint` schema | 不变 |
| `fetchTrustPermitted` 布尔逻辑 | 仅挂载点名称/注释变 |
| adapter 业务解析代码（HTML 选择器等） | 签名约定不变则零改 |
| `Ctx.fetch` 方法名 | 仍是 fetch API，不是「模式名」 |
| 历史 ADR 全文重写 | 脚注即可 |

---

*本大清单由 ADR-022 落地用；勾完 §7 即迁移完成。*
