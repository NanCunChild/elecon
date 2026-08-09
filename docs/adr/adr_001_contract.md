# ADR-001：标准数据 schema 与 Capability Manifest 规范

- **状态**：已接受（Accepted）
- **日期**：2026-06-08（**修订 2026-06-16，🔒 待人工复核**：§8 增记 `elecon.notice.list` 1.0→1.1 —— 将 `publishedAt` 由 required 放宽为可选，使其与本文 §3.4「缺失语义」对齐。触发自首个 imperative adapter（school-xjt 教务通知）实测：源站日期偶有不可解析格式，旧实现回退空串违反 `date-time` 校验。）
- **依赖**：[`adr_000_abstract.md`](./adr_000_abstract.md)
- **适用范围**：`contract/` 目录的全部内容，即 adapter↔UI、adapter↔核心之间的所有契约。本文一动，两端都受影响——改动须遵循本文 §7 的治理规则。

---

## 1. 背景（Context）

ADR-000 把"标准数据 schema + Capability Manifest"定为整个项目最重要的设计产物：

- **schema** 是 adapter 与 UI 之间唯一的耦合面：adapter 负责"某校混乱格式 → 标准 schema"，UI 只认标准 schema、与学校无关。
- **manifest** 是 adapter 对核心的声明：声明能提供什么能力、需要访问哪些域名——核心据此做凭证注入与撮合。

ADR-000 同时定下三条约束本文必须落地：①一份 adapter 客户端与服务端双跑（两端均为 QuickJS——服务端走 QuickJS-wasm，见 [`adr_005`](./adr_005_runtime.md)）；②按信任分档，第三方/侧载 adapter 退化为 declarative 纯解析；③数据用 TTL/新鲜度、代码用版本号。本文把这些从"原则"变成"可校验的规范"。

---

## 2. 决策概览（Decision）

1. **schema 的规范语言用 JSON Schema（Draft 2020-12）**，作为唯一事实来源（single source of truth），向 Dart / Go 生成类型，向 JS 提供运行期校验依据。
2. **校验发生在宿主侧的信任边界**（客户端核心 Dart / 服务端 TS，见 [`adr_005`](./adr_005_runtime.md)），不在 adapter 内部——QuickJS 不背校验器。
3. **一切归一化结果都包在统一 envelope 里**，携带来源、新鲜度、schema 版本等元数据。
4. **capability 是契约的基本单元**：`<domain>.<action>`，每个 capability 绑定一个输出 schema 与一段网络作用域。
5. **manifest 声明能力 + 网络白名单**；每 capability 声明 `requestGraph`（`declarative` | `imperative`；ADR-022）。
6. **错误也是契约**：统一的归一化错误模型，让 UI/同步层对失败有一致反应。
7. **保留 typed 模型 + 一个受约束的兜底域**：本体确实"认识"成绩/课表等 typed 域（这是产品价值与本体智能的来源）；长尾、冷门数据走一个**由本体渲染**的通用域 `elecon.generic.section`——adapter 只提供归一化数据 + 轻量**语义角色提示**，**绝不**提供样式/控件/CSS（见 §3.6）。

---

## 3. 标准数据 schema

### 3.1 为什么是 JSON Schema

| 候选 | 取 | 舍 |
|---|---|---|
| **JSON Schema（选用）** | 语言中立、可运行期校验、人类可读、贡献门槛低（写 JS adapter 的人天然熟 JSON） | 类型表达力弱于 IDL，需配 codegen 补强 |
| Protobuf / IDL | 强类型、codegen 好 | 二进制不直观、QuickJS 处理重、抬高 adapter 贡献门槛，违背"降低门槛" |
| TypeScript 类型 | DX 好 | 非中立、Dart/Go 不能直接消费、非运行期契约 |

结论：JSON Schema 当事实来源；`tools/` 生成 Dart / TS 类型；宿主在边界处校验（服务端用 `ajv`，与 `tools/` 共用一套）。**校验器只活在 Dart/TS**，adapter 产出的数据由宿主校验后才被接受，QuickJS 不引入校验负担。

### 3.2 命名空间

所有 schema 以 `elecon.` 前缀命名：

- 数据域：`elecon.grades.list`、`elecon.schedule.week`、`elecon.card.balance` …
- 入参：`elecon.params.<capability>`，如 `elecon.params.grades.list`
- 信封：`elecon.envelope`
- 错误：`elecon.error`

### 3.3 统一 Envelope

每一份跨越 adapter↔宿主 边界的归一化数据都用 envelope 包裹。**数据的新鲜度由此承载（TTL），与代码版本无关**（呼应 ADR-000 §2.4）。

```json
{
  "schema": "elecon.grades.list",
  "schemaVersion": "1.0",
  "source": {
    "schoolId": "1234",
    "adapterId": "school-1234",
    "adapterVersion": "3.2.0",
    "origin": "client-direct"        // client-direct | campus-relay | public-cache
  },
  "freshness": {
    "fetchedAt": "2026-06-08T03:00:00Z",   // RFC3339 / UTC
    "ttlSeconds": 3600,
    "stale": false
  },
  "data": { /* 见 §3.5 域负载 */ }
}
```

`origin` 让 UI 能区分数据来路（直连最鲜、公网缓存兜底），配合 `stale` 提示用户。

### 3.4 全局约定（所有域必须遵守）

- **时间**：一律 RFC3339、UTC（`...Z`）。展示时区由 UI 处理，schema 不存本地时区偏移。
- **金额**：整数 + 最小货币单位（如"分"）+ 货币码，**禁止浮点**。例：`{ "amountMinor": 1250, "currency": "CNY" }` 表示 12.50 元。一卡通余额尤其依赖这条。
- **缺失语义**：字段缺失 = 该校不提供该信息（字段可省略）；字段为 `null` = 提供该信息但本次确为空。两者语义不同。
- **ID**：均为校内作用域字符串，UI 不假设跨校唯一。
- **枚举**：未知值统一落到 `"unknown"`，禁止把未识别值丢失或瞎猜。
- **兼容**：新增可选字段 = 向后兼容；删除/改义/改类型 = 破坏性（见 §7）。

### 3.5 域负载示例（以 `elecon.grades.list` 为例）

```json
{
  "term": "2025-2026-2",
  "items": [
    {
      "courseId": "CS101",
      "courseName": "计算机导论",
      "credit": 3.0,
      "score": { "kind": "numeric", "value": 88, "max": 100 },
      "gradePoint": 3.7,
      "category": "required",        // required | elective | unknown
      "status": "final"              // final | provisional | unknown
    }
  ]
}
```

> 说明：`score.kind` 支持 `numeric` / `letter` / `passfail`，以容纳不同学校的记分制；`gradePoint` 等派生值若学校不直接给出，**由 UI/视图层计算，adapter 不擅自推算**——注意这**不是**因为"adapter 要薄"（那是能力面的安全口号，见 [`adr_000`](./adr_000_abstract.md) §3.1「两个轴」），而是因为 GPA 这类**跨校统一、本体要自己施加智能（排序 / 聚合 / 算法一致性）的派生语义**归本体所有。**反向的一类必须分清**：**校本特有的派生（如脏日期格式归一化、从校历推当前教学周、单位换算、多接口拼装）是 adapter 的重活**，应尽量吸收进 adapter，不上抛核心/UI——本体不该知道每所学校的校历。判据一句话：**跨校统一的派生 → 本体；校本特有的派生 → adapter（尽量重）。**

首批落地的域（其余按需经 ADR 扩展）：`grades`、`schedule`、`card`、`library`、`notice`，外加通用兜底域 `generic`（见 §3.6）。

### 3.6 通用兜底域 `elecon.generic.section`

typed 域（成绩/课表等）是本体智能与产品价值的来源，**不能**为了"少走 ADR"就把它们抽象成"样式命名 + adapter 自带变量"——那会一次性打掉本体的智能（算 GPA、排序、语义搜索、跨校聚合、上课提醒）、统一体验、安全模型（半可信 adapter 不得驱动渲染层）与服务端缓存（缓存依赖归一化成已知 schema）。一个只渲染、不理解数据的本体本质上只是个更差的浏览器。

但"新增/冷门数据类型就得走 ADR 慢车道"这个摩擦是真的。解法不是放弃 typed 模型，而是加**一个**通用、**由本体渲染**的兜底域：

- **形态**：受约束的"带标签字段 / 键值组 / 简单表格"。宿舍水电、实验室预约这类长尾、不值得单独立 schema 的校园特有数据走这个域，**不必每个字段都开 ADR**。
- **承重边界——必须分清两个东西，差别就是成败：**
  - **语义角色提示（adapter 可以给）**：标注某字段"是状态 / 是截止时间 / 是金额 / 是主标识 / 是链接"。落在受控枚举 `role` 上。
  - **样式（adapter 绝不能给）**：具体颜色、控件选择、布局代码——一律不接受。
- **谁决定外观**：adapter 说"这是个 deadline"，**本体的主题**决定 deadline 长什么样。这样长尾灵活性有了，而一致性、安全、本体智能一个没丢。
- **角色如何映射到主题样式**属 SDUI 范畴，归 `adr_004`（UI 层，待补，见 ADR-000 §6 索引）——本文只固定**数据 + 角色枚举**这一契约面。

角色枚举（`elecon.generic.section` 字段上的 `role`，未知值落 `"unknown"`）：

| role | 含义 |
|---|---|
| `identifier` | 主标识 / 主键字段 |
| `label` | 普通文本标签 |
| `status` | 状态（本体主题决定如何着色/打标） |
| `datetime` | 时间点（RFC3339/UTC） |
| `deadline` | 截止时间（本体可据此做提醒） |
| `amount` | 金额（遵守 §3.4 金额约定：整数 + 最小单位 + 币种） |
| `quantity` | 数量 / 计量值 |
| `link` | 链接 URL |
| `unknown` | 未识别角色（禁止丢弃或瞎猜） |

> 注意：`generic` 是**兜底**，不是"省事通道"。一旦某类数据稳定下来、值得本体施加智能（计算/排序/提醒/聚合），就应经 ADR 升级为独立 typed 域，而非长期赖在 `generic` 里。

---

## 4. Capability：契约的基本单元

一个 capability = 一个意图 + 一个输出 schema + 一段网络作用域。

- **命名**：`<domain>.<action>`，如 `grades.list`、`schedule.week`、`card.balance`、`card.transactions`、`library.loans`、`notice.list`。
- **注册表**：所有合法 capability id 收在 `contract/capability/registry.json`。**新增 id 或改其语义 = 契约变更 = 需 ADR**（呼应 feature-workflow 慢车道）。
- **绑定**：每个 capability 指定它发出的 `emits.schema`（+版本）和可选的 `params.schema`。
- **UI 绑定**：UI 的卡片通过 capability id 声明所需数据（如"成绩卡"消费 `grades.list`）。UI↔capability 的具体渲染绑定细节属 SDUI 范畴，留待 `adr_004`，本文只固定 id 作为接口。

---

## 5. Capability Manifest（adapter 的声明）

manifest 是 adapter 对核心的契约，JSON 格式，供宿主与 `tools/` 静态校验器读取。

### 5.1 公共字段

```json
{
  "manifestVersion": "1.0",
  "adapterId": "school-1234",
  "adapterVersion": "3.2.0",          // 代码版本，参与 max(本地,服务端) 解析
  "schoolId": "1234",
  "displayName": "示例大学",
  "trustTier": "official",            // official | sideload（community 已于 ADR-002 2026-06-14 移除）
  "runtime": { "engine": "quickjs", "entry": "index.js" },
  "network": {
    "allow": [
      "https://jw.example.edu.cn/api/*",
      "https://ehall.example.edu.cn/*"
    ]
  },
  "capabilities": [ /* 见 §6；每 cap 必含 requestGraph */ ]
}
```

`network.allow` 是核心的**出口闸门**：打到白名单外一律拒绝（fail-closed）。这是 capability-based security 的落点——即便 adapter 恶意，也只能在学校自己的接口范围内活动，无法拿着凭证往外带数据。

**凭证注入由可选的 `credentials` 块声明（[`adr_013`](./adr_013_manifest_credentials.md)）**，**不是**"命中白名单即注入"：

```json
"credentials": {
  "session": { "scope": ["https://jw.example.edu.cn/api/*"], "type": "cookie" }
}
```

- `credentials.<name>`：凭证引用名（= ADR-012 `CredentialEntry.ref`），值声明 `scope`（注入作用域，须 ⊆ `network.allow`）+ `type`（`cookie`/`header`）。**只含引用名 + 作用域 + 注入方式，绝不含凭证值**（红线 #1）。
- **命中 `network.allow` ≠ 注入**：仅当请求 URL 命中某 `credentials.<name>.scope` 才注入对应凭证；白名单内未被任何 scope 覆盖的 URL = passthrough（可达不注入，用于反爬挑战端点等）。
- 可选字段、向后兼容；`tools/` 校验器强制 scope ⊆ allow、scope 等长重叠拒绝、declarative `requests[].credential` 引用闭合（见 ADR-013 §2.4）。

### 5.2 信任档与 requestGraph 约束

> ⚠ **待修订（[ADR-033](./adr_033_production_sideload.md) · Proposed，2026-08-09）**：[ADR-033](./adr_033_production_sideload.md) 提议把本节约束（validator C3）的适用范围由「分发 / 签名路径」扩到**运行时**，并对生产侧载档叠加额外能力面闸门（其 §2.4 G1–G6）。 **ADR-033 接受前，本节逐字有效。**

- `trustTier: official` → 每 capability 可用 `requestGraph: imperative` 和/或 `declarative`（release 下凭证注入资格仍由 trust tier 裁定；ADR-022）。
- `trustTier: sideload` → **release 下每个 capability 强制 `requestGraph: declarative`**；`tools/` 校验器在**官方分发/签名路径**拒绝 sideload + 任一 imperative cap（`C3_sideload_must_declarative`）。**dev/debug build 例外**：无签名侧载 adapter 可跑 imperative（强警告 + 全占用确认），见 [`adr_002`](./adr_002_trust_model.md) §2.5——dev 本地加载不经此静态闸门。
- **`community` 档已移除**（ADR-002 2026-06-14 修订）：信任模型只剩 official + sideload，`trustTier` 枚举不再含 `community`（见 [`adr_002`](./adr_002_trust_model.md) §2.1）。
- **无 adapter 级 `mode`**：取数图声明性 per-capability，见 §6 / [`adr_022`](./adr_022_request_graph.md)。

---

## 6. 请求图声明性（adapter-sdk 约定；ADR-022）

同一份 adapter 在客户端与服务端以相同宿主契约被调用——两端均属 QuickJS 谱系（服务端走 QuickJS-wasm，见 [`adr_005`](./adr_005_runtime.md)），但绑定、版本和编译配置不同；共享 golden/canary 只保证覆盖到的已使用语义一致（ADR-008 §3.2）。**每 capability** 用 `requestGraph` 声明取数请求图（**required、无 default**）；同一 adapter 可混用两种图。

> 旧称「fetch 模式 / parser 模式」与顶层 `mode` 已由 [ADR-022](./adr_022_request_graph.md) 抹除。真正发请求与注入凭证的始终是核心 broker。

### 6.1 imperative requestGraph（官方签名可独占 `ctx.fetch`）

adapter 在代码里自编排请求 + 解析；核心通过受限的 `ctx.fetch` 注入凭证（仅 scope 命中时）。**adapter 拿不到凭证的值。**

manifest 片段：

```json
"capabilities": [
  {
    "id": "grades.list",
    "requestGraph": "imperative",
    "emits":  { "schema": "elecon.grades.list", "schemaVersion": "1.0" },
    "params": { "schema": "elecon.params.grades.list", "schemaVersion": "1.0" }
  }
]
```

adapter 代码：

```js
export const capabilities = {
  // ctx: { fetch, setEphemeralCookie, log, now }  —— fetch 由 broker 包装
  "grades.list": async (ctx, params) => {
    const res  = await ctx.fetch("https://jw.example.edu.cn/api/grades?term=" + params.term);
    const json = await res.json();
    return {                                  // 宿主据 emits.schema 校验后才接受
      term: params.term,
      items: json.list.map(normalizeGradeItem)
    };
  }
};
```

### 6.2 declarative requestGraph（核心代取 + 纯解析；sideload 强制）

adapter **无网络、无凭证**，退化为纯函数解析器。核心据 manifest 的请求配方代取（注入凭证、限定白名单），把原始响应交给 adapter 解析。handler **必须同步**；返回 Promise 则错误码 `async_in_declarative`。

manifest 片段（capability 额外声明 `requests` 配方）：

```json
"capabilities": [
  {
    "id": "grades.list",
    "requestGraph": "declarative",
    "emits": { "schema": "elecon.grades.list", "schemaVersion": "1.0" },
    "requests": [
      { "key": "raw", "method": "GET",
        "url": "https://jw.example.edu.cn/api/grades?term={term}",
        "credential": "session" }            // 凭证名，由核心解析，adapter 看不到值
    ]
  }
]
```

adapter 代码：

```js
export const capabilities = {
  // 注意：ctx 不含 fetch；responses 是核心代取后脱敏的原始响应
  "grades.list": (ctx, params, responses) => {
    const json = JSON.parse(responses.raw.body);
    return { term: params.term, items: json.list.map(normalizeGradeItem) };
  }
};
```

### 6.3 凭证零泄露的硬约束（两种 requestGraph 通用）

跨 adapter 边界流动的只有"请求意图"和"已脱敏结果"，绝不流动任何等价于凭证的东西：

- 交给 adapter 的 `responses` 必须剥除 `Set-Cookie`、`Authorization` 回显、重定向链中的中间 token；
- imperative 下 `ctx.fetch` 的 URL 不得由核心回填带 token 的形式给 adapter 读取；
- adapter 的返回值在被接受前由宿主按 schema 校验，**校验不通过即丢弃并返回 `parse_failed`**。

---

## 7. 错误模型（`elecon.error`）

adapter 与核心以统一错误契约表达失败，UI/同步层据此一致反应（重试、引导登录、降级到缓存）。

```json
{
  "schema": "elecon.error",
  "schemaVersion": "1.0",
  "error": {
    "kind": "auth_required",     // 见下表
    "retriable": false,
    "capability": "grades.list",
    "message": "需要重新登录"      // 安全文案，禁止含凭证/堆栈/内网细节
  }
}
```

| kind | 含义 | UI 典型反应 |
|---|---|---|
| `auth_required` | 会话失效/需登录 | 引导走对应登录流 |
| `source_unavailable` | 学校侧不可达/故障 | 降级到公网缓存（若有），提示 stale |
| `network_blocked` | 请求打到白名单外被拦 | 视为 adapter bug，记录上报 |
| `rate_limited` | 被限流 | 退避重试 |
| `parse_failed` | 归一化/校验失败 | 提示并上报，疑似学校改接口 |
| `capability_unsupported` | 该校该 adapter 不支持此能力 | UI 隐藏对应卡片 |

`message` 仅作安全展示，**不得携带凭证、堆栈、内网地址**等敏感信息。

---

## 8. 版本与兼容（治理）

- **schema 版本**：`MAJOR.MINOR`。新增可选字段 → MINOR；删除/改义/改类型/收紧约束 → MAJOR，且 ADR 须给出迁移方案与并存策略。宿主以 envelope 的 `schemaVersion` 判断如何解读。
- **manifest 版本**：`manifestVersion` 独立演进；宿主拒绝不认识的大版本。
- **adapter 版本**：参与 ADR-000 的 `max(本地, 服务端)` 解析，与数据新鲜度无关。
- **契约变更须走 ADR**：新增/修改 capability id、新增域 schema、破坏性变更，均属慢车道，默认保持向后兼容（呼应 AGENTS.md 红线 #6 与 feature-workflow）。
- **`tools/` 强制校验**：manifest 合法性、白名单越界、sideload 每 cap 必须 declarative（`C3_sideload_must_declarative`）、capability id 在注册表内、adapter 双跑（客户端 QuickJS / 服务端 QuickJS-wasm）对同一夹具产出一致——这些做成 CI 闸门，让契约从"靠人记"变"靠机器拦"。

### 8.1 变更记录（dated）

> 本节是契约新增/变更的 dated 流水（呼应红线 #6「契约变更须走 ADR」）。每条记录立项即满足"先有 ADR"。

- **2026-06-16 · `elecon.notice.list` 1.0 → 1.1（🔒 待人工复核）**
  - **改动**：`publishedAt` 由 `required` 移出，成为可选字段（schema 内容不变，仅放宽必填约束）。级联 `capability/registry.json` 与 emit 它的 manifest（school-xidian / school-xjt）的 `emits.schemaVersion` 同步至 `1.1`。
  - **为何是 MINOR 而非 MAJOR**：§8 把"收紧约束"列为破坏性，本改动是其**反向（放宽）**。§3.4「缺失语义」本就要求消费方普遍处理"字段缺失 = 该校不提供"，故把 `publishedAt` 改为可选**不超出消费方既有义务**，旧数据（含 `publishedAt`）在 1.1 下仍合法 → 向后兼容，记 MINOR。
  - **本次遇到的情况**：首个 imperative adapter（school-xjt 教务通知）逆向中，源站通知日期偶为不可解析格式；旧 `normalizeDate` 不可解析时回退空串 `""`，而 `""` 不是合法 `date-time`，会被 ajv 拒。改为不可解析时**省略 `publishedAt`**（语义 = 该条目未提供可信日期），与 §3.4 一致。
  - **是否可能引入未知问题（风险）**：
    1. **消费方（UI/SDUI）**：若某处实现假设 `publishedAt` 必存（如直接排序/格式化），缺失时可能报错或排序错位。缓解：UI 须遵 §3.4 处理缺失；按时间排序时对无日期项定义稳定兜底位次。
    2. **新旧版本并存**：1.0 与 1.1 同时在网（不同 adapter/缓存）时，宿主以 envelope `schemaVersion` 解读；1.1 消费方需容忍缺省，1.0 数据天然满足。
    3. **一致性外溢**：其他域 schema 可能存在同类"过紧 required"（如把可能缺失的字段标必填），本次只动 notice.list，未做全面审计——留作后续核对，不在本改动范围。
    4. **校验盲区**：`tools/` 校验器目前不对 params schema 做加载校验，emits 版本一致性（C2）已覆盖本次级联；fixtures 仍含 `publishedAt`，1.1 下照常通过。

- **2026-06-16 · 新增 `elecon.card.transactions` emits schema + 5 个 `params.*` 草案 schema（补 registry 悬空引用，🔒 待人工复核）**
  - **改动**：补齐 `capability/registry.json` 早已声明却**无定义文件**的 schema——
    1. **`elecon.card.transactions@1.0`（emits，稳定面）**：money 模型镜像 `card.balance`（`amountMinor` + `currency`），增 `direction`（debit/credit）区分收支；`amountMinor` 加 `minimum:0`（交易额恒非负，收支由 `direction` 表达，区别于 `card.balance` 可为负的余额，已在 schema `$comment` 注明）。
    2. **5 个 `params.*` 草案 schema**：`grades.list` / `schedule.week` / `card.transactions` / `notice.list` / `generic.section`，消除 registry 悬空 `params` 引用。均带 `$comment: 草案`。
  - **范围**：仅新增 `contract/schema/` 文件；未改 `registry.json`、未新增/改 capability id、未改任何既有 schema 语义。registry 的 `$schema` 错误指向已拆至 #48 单独修复。
  - **草案（draft）状态约定**：上述 5 个 `params.*` 在经本 ADR **正式确认（"转正"）前不属稳定契约面**——adapter / UI 不得将其当稳定依赖。**草案期内其形状可自由调整（增删字段、改约束）而不触发 §8 的 MAJOR/MINOR 版本治理**；版本治理仅自该 schema 转正后生效。此约定为契约早期高频迭代（按真实接口反复校准）留出空间，同时不削弱红线 #6——草案明标、不被依赖、转正须在本节补记。
  - **待人工确认的设计点（草案期跟进，非阻塞本次补齐）**：
    1. `params.schedule.week.week` 设为 `required` 是否需核心侧配套「当前教学周」能力（否则消费方无从得知传第几周）；
     2. `params.card.transactions` 的 `from`/`to` 与 `page`/`size`：已知学校（XIDIAN）流水接口仅支持分页（`pageNo`/`pageSize`）、不支持日期范围，故 `from`/`to` 设可选以适配跨校差异，由 adapter 归一化映射。

- **2026-07-22 · `classroom.available` 1.0 → 1.1 + 新增 `classroom.buildings`（ADR-019）**
  - **改动**：
    1. **`elecon.params.classroom.available` / `elecon.classroom.available` → 1.1**：双时间轴（`date`/`week`/`term`/`weekday` + 节次 `sectionStart`/`sectionEnd` + 墙钟 `start`/`end`）；楼/室过滤 `building`/`buildingId`/`room`/`roomId`；`onlyAvailable`；emits 增 `sections[]`（`maxItems:24`）、`status` 枚举追加 `partial`、`timeZone`（IANA，adapter 声明）、`floor` 等。`items[].building`+`room` 仍 required 且 `minLength:1`，未知填 `"-"`。
    2. **新增伴生 capability `classroom.buildings@1.0`**（discovery）：params 可选 `campus`/`term`；emits `items[]` required `building`。
    3. registry 级联 `schemaVersion`；codegen Dart/TS 同步。
  - **为何是 MINOR**：仅新增可选字段 + 枚举扩展（放宽消费方须按 §3.4 对未知枚举兜底 `unknown`）+ 新 capability；不删字段、不改既有类型；旧 1.0 数据在 1.1 下仍合法。
  - **依据**：[ADR-019](./adr_019_classroom_available.md)（2026-07-22 Accepted）。

---

## 9. 取舍（Consequences）


**收益**
- adapter 与 UI 彻底解耦，UI 不含任何学校逻辑；新学校只写 adapter + manifest。
- 网络白名单 + per-capability `requestGraph` 把"能力分档"从人工审查变成机制约束，侧载 adapter 即便恶意也被关进 declarative 纯解析器的笼子。
- 统一 envelope/错误模型让同步层、缓存、降级有一致依据。

**代价 / 已知约束**
- JSON Schema 类型表达力有限，依赖 codegen 与边界校验补强；增加 `tools/` 的维护面。
- declarative requestGraph 要求 manifest 声明请求配方，使"取数逻辑"与"解析逻辑"分处两地（manifest 声明 vs adapter 代码），对 declarative adapter 作者是额外心智负担——这是为隔离性付的价。
- 统一金额/时间/缺失语义等约定需要 adapter 作者严格遵守，靠 `tools/` 校验兜底，但语义正确性（如归一化是否真的对）仍需夹具回归保证。
- 首批只覆盖 5 个域；扩展每个新域都要走 ADR，节奏受治理流程约束（这是刻意的——契约稳定优先于扩张速度）。

---

## 10. 落地清单（指向 `contract/` 骨架）

- `contract/schema/`：`envelope`、`error`、`grades.list`、`schedule.week`、`card.balance`、`library.loans`、`notice.list`、`generic.section` 的 JSON Schema 与对应 `params.*`。
- `contract/capability/registry.json`：首批 capability id 注册表。
- `contract/manifest.schema.json`：manifest 自身的 JSON Schema（供 `tools/` 校验 manifest；无顶层 `mode`，每 cap 强制 `requestGraph`，ADR-022）。
- `contract/adapter-sdk/`：`ctx` 与 capability handler 的类型声明（`CtxDeclarative` / `CtxImperative` 两种签名）。
- `adapters/_template/{declarative,imperative}/`：两种 requestGraph 的脚手架样例。
