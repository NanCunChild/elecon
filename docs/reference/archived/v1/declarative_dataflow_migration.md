# 落地大清单：ADR-023 声明式跨请求数据流

> 历史上落实 [V1 ADR-023](../adr/archived/v1/adr_023_declarative_dataflow.md)。V2 已退役该方向，本文仅用于迁移清理。
>
> ADR-022 已完成迁移并作为前置条件。本文涉及凭证派生值、句柄解引用、注入和响应脱敏，属于安全承重路径：实现与测试必须人工主导，配套安全清单，并至少经过 1 名人工审阅；AI 不得独自闭环。
>
> **当前状态：✅ MVP 已落地（2026-07-24）。** §2 契约 + §3 validator + §4 服务端参考执行器/golden + §5 客户端对称执行器/接线 + §6 迁移登记全部完成；owner 人工安全审 + 代码签收通过（安全清单三处缺陷已修复补测）。§0 全部 7 项已勾决（第 7 项 owner 定为**不加 `if/then`**，组合约束全归 validator）。后续增量见文末。
>
> **动工门禁**：第 7 项直接决定 §2 契约的实现方式（schema 承担多少组合约束）。**已决：schema 不加 `if/then`**（§0 第 7 项），`bind/compute/inject` 的组合约束由 validator D1–D16 承担。两端 broker/runtime（§4/§5）仍按 §8 顺序排在契约与 validator 之后；§4/§5/§6 属 🔒 人工主导路径，AI 不得独自闭环。
>
> **已落地产物（§2/§3）**：
> - `contract/manifest.schema.json`：per declarative capability 增 `bind`/`compute`/`inject` 三段（字段形状 + 封闭枚举 + 类型标签由 schema 承担）。
> - `docs/reference/declarative_dataflow_ops.md`：逐 op 形式化语义表（validator 签名检查与两端 runtime 的共同事实来源）。
> - `tools/src/validator/dataflow.ts`：规则 D1–D16（引用闭合/DAG 无环/静态类型/密钥形态/复杂度限额/汇聚点/信任门/凭证头护栏）。
> - `tools/src/validator/dataflow.smoke.ts`：正例 + 15 组安全负例，`npm run smoke:dataflow`。
> - `adapters/_template/declarative`：挑战页→派生→注入的端到端示例 manifest（adapter 解析仍纯末端）。

## 0. 落地前必须勾决

对应 ADR-023 §5。**2026-07-24 owner 勾决：1–6 已决，第 7 项仍开放。** 决策全文与理由见 ADR-023 §5；本节只留实施摘要。

- [x] **提取器首批词表**：放行 `header(name)` / `body(jsonpath)` / `regex(pattern,group)`；**`css-select` 不进首批**（标记可扩展，非否决）。匹配数量 **= 1**（标量句柄，**不支持数组句柄**）。失败语义见决策 6。
- [x] **`compute` 首批封闭 op 词表**：`concat` / `substring` / `base64` / `hex` / `urlencode` / `hmac-sha256` / `hkdf` / 签名方案枚举 id / **`now`**。**禁 `random` / `uuid`**（破双跑 golden）。
- [x] **允许 compute 嵌套 / 引用前置输出**；深度 16、节点 64、每 op 参数 8、无环 + 引用闭合。
- [x] **MVP 允许凭证派生值**；🔒 回显剥离为 MVP 必做项；残余风险（比较预言机、长度预言机）已由 owner 明示接受，见 ADR-023 §2.5。
- [x] **`devSideload` 在 DEV 下与 official 同权**（推翻初稿 official-only）；🔒 防扩散条款见 ADR-023 §2.6——能力判定挂 `devSideload` 档本身，**不得写成「非 official 即放行」的否定式**。
- [x] **缺失语义统一 fail-closed**：提取失败 / 匹配失败 / 注入时句柄缺失 → 整条 capability 失败；**不提供「缺失即省略下游注入」**。🔒 错误只进宿主日志与用户诊断，**绝不回流 adapter**。
- [x] **（已决 2026-07-24）** owner 确认**保持 schema 层不新增 `if/then`**，由 validator（D1–D16）承担 `bind/compute/inject` 组合约束（同 ADR-022 走 validator C12 的先例；本 ADR 约束本质超出 JSON Schema 表达力）。ADR-023 §5 第 7 项同步定稿。

### 0.1 限额常量（实施基准，两端必须一致）

| 限额 | 值 | 说明 |
|---|---|---|
| `header` 提取输入 | 4 KB | |
| `body` 提取输入 | 8 MB | **对齐现有 `DEFAULT_MAX_BODY_BYTES`**（`server/src/runtime/transport/direct.ts`），不新造 |
| `regex` 提取输入 | 8 KB | |
| **单句柄值上限** | **64 KB** | 🔒 主闸门 |
| **全 DAG 句柄总预算** | **4 MB** | 🔒 主闸门，超出 fail-closed |
| compute 嵌套深度 | 16 | 纵深 |
| compute 节点数 | 64 | 纵深 |
| 每 op 参数个数 | 8 | 纵深 |
| 请求数 | 复用现有 `maxRequests`（默认 20） | 不新造 |
| `regex` 回溯步数预算 | 待实现时定值 | 🔒 见 0.2 |

🔒 **限额必须同时约束输出**：`concat` 可自我倍增，仅限输入时嵌套 16 层即 2¹⁶ 倍放大。单句柄 64 KB + 全 DAG 4 MB 是主防线，深度/节点数只是纵深。

### 0.2 随决策生效的三条实现约束 🔒

1. **`regex` 的闸门是回溯步数预算 + 语法白名单，不是输入大小**：输入上限挡不住灾难性回溯，而模式串由 adapter 作者提供。首批语法子集**禁嵌套量词、禁 lookbehind**；超步数预算 → fail-closed 错误（非超时）。两端步数计数须一致，否则双跑 golden 漂移。
2. **句柄类型化（bytes / text）**：`hmac-sha256`/`hkdf` 产出原始字节；`base64`/`hex` 是唯一 bytes→text 通道；类型不匹配由 validator **静态**拒绝。**须配套两端类型语义测试**。
3. **`hmac-sha256`/`hkdf` 的 key 只能是句柄引用，不得是字面量**：manifest 是已签名分发的产物，字面量密钥等于公开。

## 1. 不变量与范围

> 状态标注：[x]=已由代码/测试保证；括注实现点。人工安全审仍须逐条复核（§7）。

- [x] adapter 只持有变量名/不透明句柄，永远不能读取句柄字节。（句柄只存在于 host 侧 broker/dataflow；`CtxDeclarative` 无句柄 API；adapter 只收脱敏后 `responses`。）
- [x] 抽取只读取响应头/body；不得读取 broker 注入的请求头或凭证值。（`extractHandle` 只吃 `RawResponse`{status,headers,body}，无请求侧入参。）
- [x] 数据流是固定 DAG；拓扑、`inject.into/at/name` 均静态可枚举。（schema 静态声明 + validator D12/D15；`planRequestOrder` 纯据声明推导。）
- [x] `tainted` 值不得决定分支、请求数量、目标请求或 adapter 输出。（声明面无分支构造；汇聚点静态；句柄不进 adapter 解析输出——格式自带，MVP 期免费成立，ADR-023 §2.5。）
- [x] 响应交给 adapter 前剥除 `Set-Cookie`、Authorization、重定向 token 及注入值回显。（`processResponse` allowlist + `stripEchoes` 注入值回显剥离。）
- [x] 命令式仍只覆盖动态拓扑和不可枚举计算；固定拓扑数据依赖迁回 declarative。（§6：`school-xjt` 保留 imperative 已登记理由；参考试点为 `_template/declarative`。）

## 2. 契约与 SDK

- [x] `contract/manifest.schema.json` 为 declarative capability 增加 `bind`、`compute`、`inject`。
- [x] schema 限定提取器、compute op、注入位置和引用名的封闭集合。
- [x] 明确并实现数组唯一性、引用闭合、DAG 无环、静态汇聚点和字段类型约束。（形状+封闭枚举由 schema；引用闭合/无环/类型/汇聚点由 validator D3/D7/D9/D12/D15，见 §0 第 7 项决策。）
- [x] 提取器枚举**只放行** `header` / `body` / `regex`（**`css-select` 不进首批**）；`bind` 结果恒为标量，**不引入数组句柄**。
- [x] compute op 枚举含 `now`，**不含** `random` / `uuid`（双跑 golden 不变量）。
- [x] 句柄声明**带类型标签（bytes / text）**；`base64` / `hex` 为唯一 bytes→text 通道。（类型标签为**静态推导**：bind→text、hmac/hkdf→bytes，adapter 不显式写 type；validator D9 强制。逐 op 见 `declarative_dataflow_ops.md`。）
- [ ] ~~`contract/adapter-sdk/types.d.ts` 同步声明面~~；adapter 不获得响应值或句柄解引用 API。**（无需改动：`CtxDeclarative` 已无 fetch/句柄 API，`bind/compute/inject` 是 manifest 声明面而非 adapter 运行期 API 面，types.d.ts 只描述后者。已复核确认。）**
- [x] 更新 schema golden 与脱敏 fixture；禁止真实学生数据和真实凭证。（`adapters/_template/declarative` 端到端示例；无真实数据。）

## 3. Validator 🔒

> 落地于 `tools/src/validator/dataflow.ts`（规则 D1–D16），接入 `checkManifest`。负例见 `dataflow.smoke.ts`。

- [x] 校验 `bind.from` 指向已声明 request，source/extract 符合封闭词表。（D2/D4）
- [x] 校验 compute 输入变量已定义且 op 合法；拒绝循环、未定义引用和越界复杂度。（D6/D7/D8/D11；无环由「只引用声明序在前」+ D15 请求依赖 DFS 双重保证）
- [x] 校验 inject 目标 request、位置、字段名静态且引用已定义。（D12）
- [x] **静态类型检查**：句柄 bytes/text 类型匹配，不匹配即拒（如 `concat` 混接 bytes 与 text）。（D9）
- [x] **`hmac-sha256`/`hkdf` 的 key 必须是句柄引用**，字面量密钥一律拒（manifest 已签名分发 = 公开）。（D10）
- [x] **静态复杂度限额**：嵌套深度 ≤16、节点数 ≤64、每 op 参数 ≤8（§0.1）。（D11）
- [x] **`regex` 语法白名单**：禁嵌套量词、禁 lookbehind、禁反向引用/命名组；模式串静态校验。（D5，`checkRegexSyntax`）
- [x] 校验 declarative-only 与信任门：**能力判定挂 `devSideload` 档本身**，🔒 **不得写成「非 official 即放行」的否定式**（ADR-023 §2.6 防扩散条款）。（D1 + D13 `DATAFLOW_ALLOWED_TRUST_TIERS` 正向允许表）
- [~] 为缺失值、凭证派生值、回显值、越界注入、循环和非法 op 增加安全负例。**（静态可查项已覆盖：非法 op/越界注入/循环 = D8/D12/D15/D16 负例；缺失值语义、凭证派生值回显剥离属**运行期** fail-closed，随 §4/§5 runtime 落地并配 golden。）**
- [x] 新增安全负例：类型不匹配、字面量 key、超深度/超节点/超参数、非法 regex 语法。（dataflow.smoke.ts）
- [x] 运行 validator smoke、schema golden 和全量 adapter validate。（`smoke:dataflow` + `smoke:validator` + `smoke:all` 15/15 + `validate` 5/5 通过）

## 4. Server runtime / broker 🔒

> **落地**：`server/src/runtime/broker/dataflow.ts`（TS 参考执行器 = 语言无关 golden 基准，非生产代取，红线 #2）+ `dataflow.smoke.ts`（39 例）。逐 op 语义权威见 `declarative_dataflow_ops.md`。人工安全审见 `declarative_dataflow_security_checklist.md`（A–F 全绿，owner 2026-07-24 签收）；下方括注为对应清单条目。

- [x] 在现有 declarative 代取 seam 上实现请求依赖拓扑排序；无依赖请求可并发。（`planRequestOrder` Kahn 分层，层内保声明序、确定性；成环兜底 fail-closed。清单 D5。）
- [x] 在脱敏前完成 broker 侧提取，句柄仅存在于 broker 内部。（`extractHandle` 读脱敏前 `RawResponse`，句柄只存执行器内部 `env`。清单 A2/A5。）
- [x] 实现封闭 compute op；不得引入任意脚本执行或新运行时依赖。（`evalOp` 封闭 `switch`，仅依赖 `node:crypto`；无脚本引擎。清单 A10。）
- [x] **运行时限额执行**：单句柄 64 KB、全 DAG 句柄总预算 4 MB，超出 fail-closed（§0.1）。（`MAX_HANDLE_BYTES`/`MAX_DAG_HANDLE_BYTES`，`capText`/`capBytes` 约束**输出**防自倍增。清单 C1/C2。）
- [~] **`regex` 回溯步数预算**：超预算抛 fail-closed 错误（非超时）；两端步数计数一致。**（MVP 延后 — owner 决策，清单 E3/G2：靠 D5 语法白名单 + 8 KB 输入上限兜底，两端均用原生引擎 `exec`/`firstMatch`、无逐步计数，故无 golden 漂移；灾难性回溯残余风险已知情接受。触发实现见文末增量。）**
- [x] **`now` 由既有 `AdapterRunInput.nowMs` 喂入定值**（复用现有固定 `NOW` golden 约定），不得读真实时钟。（`formatNow(nowMs, …)` 三格式；清单 D3。）
- [x] **逐 op 形式化语义表 + 每 op ≥1 条双端 golden**：重点 `substring` 越界（JS 钳制 vs Dart 抛）、`urlencode` 变体（component/query/RFC3986，空格 `%20` vs `+`）。（`declarative_dataflow_ops.md` + `dataflow.json`；`substring` 两端统一 fail-closed 不钳制。清单 C4/D1。）
- [x] 复用现有 credential injection seam，并对注入请求执行 fail-closed 校验。（注入与凭证注入同侧叠加，越 `brokerInjectHeaders` 护栏 → fail-closed。清单 A4。）
- [x] 剥离响应中的凭证、注入值回显和重定向中间 token（🔒 **回显剥离为 MVP 必做项**，ADR-023 §2.5）。（`stripEchoes` 剥全部非空注入值 + url 编码形回显。清单 A5/B7。）
- [x] **错误只进宿主日志 / 用户诊断，绝不回流 adapter**：adapter 侧观测到的须是整条 capability 失败，与正常失败路径不可区分。（`DataflowError` message 不含句柄值。清单 A8。）
- [x] 增加双端 golden、拓扑/超时/请求数/响应大小/错误路径测试。（拓扑/输入大小/错误路径由 `dataflow.smoke.ts` + `dataflow.json` 覆盖；请求数/超时属传输层，由 client host 侧 `declarative_dataflow_host_test.dart` 覆盖。清单 D1/F1。）
- [x] 完成安全清单和人工 runtime/broker 审阅后才可合并。（owner 2026-07-24 逐条签收，见清单「签收」段。）

## 5. Client runtime 🔒

> **落地**：`client/lib/core/broker/dataflow.dart`（Dart 生产执行器，与 §4 TS 逐字节对称）+ 接线 `declarative_host.dart` `fulfillDeclarativeRequests` + `fetch_proxy.dart` 脱敏前抽取钩子/置头。客户端是唯一生产编排方（凭证在客户端核心）。人工审见安全清单 A–F。

- [x] 在 `client/lib/core/declarative_host.dart` 实现与 server 对称的 DAG 执行。（执行器 `dataflow.dart` 同名纯函数 `planRequestOrder`/`extractHandle`/`evalOp`/`resolveInjections`/`stripEchoes`，接线进 `fulfillDeclarativeRequests`。清单 D1/D5。）
- [x] 保证客户端 QuickJS adapter 仍只执行末端同步解析，不接触句柄或中间响应。（`CtxDeclarative` 无句柄/fetch API；adapter 只收 `stripEchoes` 后 `responses`。清单 A1/A10。）
- [x] 对凭证 scope、静态注入位置、请求上限、超时和响应脱敏保持 fail-closed。（`tryReserveRequest` 复用 `maxRequests`；汇聚点静态；缺失/越界统一 fail-closed。清单 A4/A5/A7/B1/C5。）
- [~] **与 server 对称实现**：§0.1 全部限额、`regex` 步数预算、句柄类型语义、`now` 定值喂入、错误只进宿主日志。**（限额/类型语义/`now`/错误路径均与 §4 逐字节对称并双跑 golden 锁定；唯 `regex` 步数预算两端**一致地延后**（清单 E3/G2），非单端缺口。审阅 issue 3 已修正 `handleByteLen` 用 UTF-8 字节口径以消除全 DAG 计量跨端漂移。清单 C2/D1–D5。）**
- [x] 增加 Dart golden，与 server 对同一 fixture 产出完全一致（含逐 op 语义 golden）。（`broker_dataflow_test.dart` 跑 `contract/golden/broker/dataflow.json`，与 server smoke 逐字节一致。清单 D1。）
- [x] 增加客户端安全负例并完成人工 runtime 审阅。（`declarative_dataflow_host_test.dart` 端到端 + fail-closed 负例；owner 2026-07-24 签收 §4/§5 取数路径。清单 F1/F3/签收。）

## 6. Adapter 迁移

> **2026-07-24 决策（owner）**：当前仓库**无合格迁移标的**——唯二的 imperative capability
> 都不满足「固定拓扑 + 纯提取/封闭计算」：`school-xjt` `notice.list` 命中动态拓扑 + 指纹伪造
> （应保留 imperative，已在其 README 登记理由）；`school-helloworld` `app.announcement` 不发
> 请求（返回常量 + `now()`，无 requests 可声明）。故**以 `adapters/_template/declarative` 的
> dataflow 示例为参考试点**，记录前后请求图与回归；真实合格 adapter 出现时再按本表逐个迁移。

- [x] ~~选定 imperative capability 作为试点~~ → 无合格标的；以 `_template/declarative`（挑战页→
  regex 抽 `client_id`→url 注入）为**参考试点**，前后请求图见其 README「声明式跨请求数据流示例」。
- [x] 参考试点为 declarative `bind`/`inject`，业务解析（`index.js`）保持末端纯解析（只读 `responses.raw`）。
- [~] 脱敏 replay fixture、schema golden 和双端回归：**dataflow 编排回归**由
  `client/test/declarative_dataflow_host_test.dart`（FakeTransport 端到端）覆盖；**执行器语义**
  双端 golden 由 `contract/golden/broker/dataflow.json` + 两端 smoke 覆盖；schema golden 由
  `npm run validate` 对模板 manifest 覆盖。**真实站点 replay fixture 待真实 adapter**（模板无真实
  站点来源，不虚构）。
- [ ] 仅在（真实）试点通过人工安全审阅后，逐个迁移其它 capability。
- [x] 对仍保留 imperative 的 capability 写明理由：`school-xjt` README 已登记（动态拓扑 + 不可枚举
  指纹计算 + 值回读，ADR-022 §2.5 两类）。

## 7. 收尾与发布门槛

- [x] contract、validator、server、client、adapter 的测试全通过。（tools `smoke:dataflow` + `validate` 5/5；server `smoke:dataflow` 39 例；client `flutter test` 568 全绿。）
- [x] server/client golden 双跑一致。（`contract/golden/broker/dataflow.json` 由 server smoke 与 client `broker_dataflow_test.dart` 各自跑，产出 == expected，逐字节一致。）
- [x] 全仓检查旧平铺代取假设、开放的句柄值、非静态注入和任意 compute。（本轮引入的路径均 fail-closed；owner 人工安全审已覆盖，见安全清单 B 组。）
- [x] 检查 release 下 sideload 门禁未被放宽，公网服务端仍无凭证存储。（D13 正向允许表未放宽 release；服务端 dataflow 为 golden 基准、无凭证存储；ADR-024 DEPLOY profile 剔除路径经 owner 复核。）
- [x] 🔒 **人工安全签收 + owner 签收（2026-07-24）**：owner 逐条复核安全清单（`declarative_dataflow_security_checklist.md`）A–F 全绿、G 组残余风险知情接受，并签收 §4/§5 触红线 #1 取数路径的代码与测试。三处审阅缺陷（url 编码回显 / 短值回读 / DAG 计量不对称）已修复并补测（commit `67f3319`）。

## 8. 建议实施顺序

1. 完成 §0 决策并更新 ADR-023。
2. 先做 validator/schema 设计和安全负例，不接 runtime。
3. 实现 server broker 与 golden，再实现 client 对称路径。
4. 以一个 adapter capability 试点迁移。
5. 通过人工安全审阅后扩大迁移范围并完成收尾。

*本清单由 ADR-023 落地使用；所有条目完成且人工签收后，才可称 ADR-023 已落地。*

**✅ 落地完成（2026-07-24）**：§0–§7 全部完成，owner 人工安全审 + 代码签收通过（安全清单 `declarative_dataflow_security_checklist.md`）。**ADR-023 MVP 已落地。** 后续增量（真实 adapter 迁移、污点自动围栏、regex 步数预算、`css-select`/任意计算/`at:body` 扩展）按各自触发条件另启。
