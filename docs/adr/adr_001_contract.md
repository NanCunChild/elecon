# ADR-001：标准数据 schema 与 Capability Manifest 规范

- **状态**：已接受（Accepted）
- **日期**：2026-06-08
- **依赖**：[`adr_000_abstract.md`](./adr_000_abstract.md)
- **适用范围**：`contract/` 目录的全部内容，即 adapter↔UI、adapter↔核心之间的所有契约。本文一动，两端都受影响——改动须遵循本文 §7 的治理规则。

---

## 1. 背景（Context）

ADR-000 把"标准数据 schema + Capability Manifest"定为整个项目最重要的设计产物：

- **schema** 是 adapter 与 UI 之间唯一的耦合面：adapter 负责"某校混乱格式 → 标准 schema"，UI 只认标准 schema、与学校无关。
- **manifest** 是 adapter 对核心的声明：声明能提供什么能力、需要访问哪些域名——核心据此做凭证注入与撮合。

ADR-000 同时定下三条约束本文必须落地：①一份 adapter 客户端与服务端双跑（两端均为 QuickJS——服务端走 QuickJS-wasm，见 [`adr_005`](./adr_005_runtime.md)）；②按信任分档，第三方/侧载 adapter 退化为纯解析器；③数据用 TTL/新鲜度、代码用版本号。本文把这些从"原则"变成"可校验的规范"。

---

## 2. 决策概览（Decision）

1. **schema 的规范语言用 JSON Schema（Draft 2020-12）**，作为唯一事实来源（single source of truth），向 Dart / Go 生成类型，向 JS 提供运行期校验依据。
2. **校验发生在宿主侧的信任边界**（客户端核心 Dart / 服务端 TS，见 [`adr_005`](./adr_005_runtime.md)），不在 adapter 内部——QuickJS 不背校验器。
3. **一切归一化结果都包在统一 envelope 里**，携带来源、新鲜度、schema 版本等元数据。
4. **capability 是契约的基本单元**：`<domain>.<action>`，每个 capability 绑定一个输出 schema 与一段网络作用域。
5. **manifest 声明能力 + 网络白名单**，并据 adapter 的信任档分 `fetch` / `parser` 两种调用模式。
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

> 说明：`score.kind` 支持 `numeric` / `letter` / `passfail`，以容纳不同学校的记分制；`gradePoint` 等派生值若学校不直接给出，**由 UI/视图层计算，adapter 不擅自推算**（adapter 越薄越好）。

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
  "trustTier": "official",            // official | community | sideload
  "mode": "fetch",                    // fetch | parser（见 §6）
  "runtime": { "engine": "quickjs", "entry": "index.js" },
  "network": {
    "allow": [
      "https://jw.example.edu.cn/api/*",
      "https://ehall.example.edu.cn/*"
    ]
  },
  "capabilities": [ /* 见 §6 */ ]
}
```

`network.allow` 是核心做凭证注入的依据：**只有命中白名单的请求才会被注入凭证；打到白名单外一律不带凭证（或直接拒）**。这是 capability-based security 的落点——即便 adapter 恶意，也只能在学校自己的接口范围内活动，无法拿着凭证往外带数据。

### 5.2 信任档与可用配置的约束

- `trustTier: official` → 可用 `mode: fetch`。
- `trustTier: sideload`（第三方侧载）→ **强制 `mode: parser`**；`tools/` 校验器拒绝 sideload + fetch 的组合。
- `community` 的策略由 `adr_002`（插件信任模型）细化，本文只固定字段。

---

## 6. 两种调用模式（adapter-sdk 约定）

同一份 adapter 在客户端与服务端以相同语义被调用——两端均为 QuickJS（服务端走 QuickJS-wasm，见 [`adr_005`](./adr_005_runtime.md)），零语义漂移。模式由 manifest `mode` 决定。

### 6.1 fetch 模式（官方签名 adapter）

adapter 自己发请求 + 解析；核心通过受限的 `ctx.fetch` 注入凭证（仅白名单内）。**adapter 拿不到凭证的值。**

manifest 片段：

```json
"capabilities": [
  {
    "id": "grades.list",
    "emits":  { "schema": "elecon.grades.list", "schemaVersion": "1.0" },
    "params": { "schema": "elecon.params.grades.list", "schemaVersion": "1.0" }
  }
]
```

adapter 代码：

```js
export const capabilities = {
  // ctx: { fetch, log, now }  —— fetch 由 broker 包装，命中白名单才注入凭证
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

### 6.2 parser 模式（第三方 / 侧载 adapter）

adapter **无网络、无凭证**，退化为纯函数解析器。核心据 manifest 的请求配方代取（注入凭证、限定白名单），把原始响应交给 adapter 解析。

manifest 片段（capability 额外声明 `requests` 配方）：

```json
"capabilities": [
  {
    "id": "grades.list",
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

### 6.3 凭证零泄露的硬约束（两模式通用）

跨 adapter 边界流动的只有"请求意图"和"已脱敏结果"，绝不流动任何等价于凭证的东西：

- 交给 adapter 的 `responses` 必须剥除 `Set-Cookie`、`Authorization` 回显、重定向链中的中间 token；
- fetch 模式下 `ctx.fetch` 的 URL 不得由核心回填带 token 的形式给 adapter 读取；
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
- **`tools/` 强制校验**：manifest 合法性、白名单越界、sideload 必须 parser、capability id 在注册表内、adapter 双跑（客户端 QuickJS / 服务端 QuickJS-wasm）对同一夹具产出一致——这些做成 CI 闸门，让契约从"靠人记"变"靠机器拦"。

---

## 9. 取舍（Consequences）

**收益**
- adapter 与 UI 彻底解耦，UI 不含任何学校逻辑；新学校只写 adapter + manifest。
- 网络白名单 + 两种模式把"能力分档"从人工审查变成机制约束，侧载 adapter 即便恶意也被关进纯解析器的笼子。
- 统一 envelope/错误模型让同步层、缓存、降级有一致依据。

**代价 / 已知约束**
- JSON Schema 类型表达力有限，依赖 codegen 与边界校验补强；增加 `tools/` 的维护面。
- parser 模式要求 manifest 声明请求配方，使"取数逻辑"与"解析逻辑"分处两地（manifest 声明 vs adapter 代码），对 parser 模式 adapter 作者是额外心智负担——这是为隔离性付的价。
- 统一金额/时间/缺失语义等约定需要 adapter 作者严格遵守，靠 `tools/` 校验兜底，但语义正确性（如归一化是否真的对）仍需夹具回归保证。
- 首批只覆盖 5 个域；扩展每个新域都要走 ADR，节奏受治理流程约束（这是刻意的——契约稳定优先于扩张速度）。

---

## 10. 落地清单（指向 `contract/` 骨架）

- `contract/schema/`：`envelope`、`error`、`grades.list`、`schedule.week`、`card.balance`、`library.loans`、`notice.list`、`generic.section` 的 JSON Schema 与对应 `params.*`。
- `contract/capability/registry.json`：首批 capability id 注册表。
- `contract/manifest.schema.json`：manifest 自身的 JSON Schema（供 `tools/` 校验 manifest）。
- `contract/adapter-sdk/`：`ctx` 与 capability handler 的类型声明（fetch / parser 两种签名）。
- `adapters/_template/`：分别给 fetch 与 parser 两种模式的脚手架样例。
