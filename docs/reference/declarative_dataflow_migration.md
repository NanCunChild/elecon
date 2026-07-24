# 落地大清单：ADR-023 声明式跨请求数据流

> 落 [ADR-023](../adr/adr_023_declarative_dataflow.md)。本文只跟踪落地，不替代 ADR。
>
> ADR-022 已完成迁移并作为前置条件。本文涉及凭证派生值、句柄解引用、注入和响应脱敏，属于安全承重路径：实现与测试必须人工主导，配套安全清单，并至少经过 1 名人工审阅；AI 不得独自闭环。
>
> **当前状态：决策已勾决（2026-07-24），待动工。** §0 的第 1–6 项已由 owner 勾决并写回 ADR-023 §2.5 / §2.6 / §5；**第 7 项（schema 是否新增 `if/then`）仍开放**。
>
> **动工门禁**：第 7 项直接决定 §2 契约的实现方式（schema 承担多少组合约束），故 **`contract/manifest.schema.json` 动工前须先决第 7 项**；§3 validator 的规则设计与安全负例可依 §0.1 / §0.2 先行。两端 broker/runtime（§4/§5）仍按 §8 顺序排在契约与 validator 之后。

## 0. 落地前必须勾决

对应 ADR-023 §5。**2026-07-24 owner 勾决：1–6 已决，第 7 项仍开放。** 决策全文与理由见 ADR-023 §5；本节只留实施摘要。

- [x] **提取器首批词表**：放行 `header(name)` / `body(jsonpath)` / `regex(pattern,group)`；**`css-select` 不进首批**（标记可扩展，非否决）。匹配数量 **= 1**（标量句柄，**不支持数组句柄**）。失败语义见决策 6。
- [x] **`compute` 首批封闭 op 词表**：`concat` / `substring` / `base64` / `hex` / `urlencode` / `hmac-sha256` / `hkdf` / 签名方案枚举 id / **`now`**。**禁 `random` / `uuid`**（破双跑 golden）。
- [x] **允许 compute 嵌套 / 引用前置输出**；深度 16、节点 64、每 op 参数 8、无环 + 引用闭合。
- [x] **MVP 允许凭证派生值**；🔒 回显剥离为 MVP 必做项；残余风险（比较预言机、长度预言机）已由 owner 明示接受，见 ADR-023 §2.5。
- [x] **`devSideload` 在 DEV 下与 official 同权**（推翻初稿 official-only）；🔒 防扩散条款见 ADR-023 §2.6——能力判定挂 `devSideload` 档本身，**不得写成「非 official 即放行」的否定式**。
- [x] **缺失语义统一 fail-closed**：提取失败 / 匹配失败 / 注入时句柄缺失 → 整条 capability 失败；**不提供「缺失即省略下游注入」**。🔒 错误只进宿主日志与用户诊断，**绝不回流 adapter**。
- [ ] **（仍开放）** owner 确认是否保持 schema 层不新增 `if/then`，由 validator 承担 `bind/compute/inject` 组合约束。**建议：保持不加**（同 ADR-022 走 validator C12 的先例；本 ADR 约束本质超出 JSON Schema 表达力）。

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

- [ ] adapter 只持有变量名/不透明句柄，永远不能读取句柄字节。
- [ ] 抽取只读取响应头/body；不得读取 broker 注入的请求头或凭证值。
- [ ] 数据流是固定 DAG；拓扑、`inject.into/at/name` 均静态可枚举。
- [ ] `tainted` 值不得决定分支、请求数量、目标请求或 adapter 输出。
- [ ] 响应交给 adapter 前剥除 `Set-Cookie`、Authorization、重定向 token 及注入值回显。
- [ ] 命令式仍只覆盖动态拓扑和不可枚举计算；固定拓扑数据依赖迁回 declarative。

## 2. 契约与 SDK

- [ ] `contract/manifest.schema.json` 为 declarative capability 增加 `bind`、`compute`、`inject`。
- [ ] schema 限定提取器、compute op、注入位置和引用名的封闭集合。
- [ ] 明确并实现数组唯一性、引用闭合、DAG 无环、静态汇聚点和字段类型约束。
- [ ] 提取器枚举**只放行** `header` / `body` / `regex`（**`css-select` 不进首批**）；`bind` 结果恒为标量，**不引入数组句柄**。
- [ ] compute op 枚举含 `now`，**不含** `random` / `uuid`（双跑 golden 不变量）。
- [ ] 句柄声明**带类型标签（bytes / text）**；`base64` / `hex` 为唯一 bytes→text 通道。
- [ ] `contract/adapter-sdk/types.d.ts` 同步声明面；adapter 不获得响应值或句柄解引用 API。
- [ ] 更新 schema golden 与脱敏 fixture；禁止真实学生数据和真实凭证。

## 3. Validator 🔒

- [ ] 校验 `bind.from` 指向已声明 request，source/extract 符合封闭词表。
- [ ] 校验 compute 输入变量已定义且 op 合法；拒绝循环、未定义引用和越界复杂度。
- [ ] 校验 inject 目标 request、位置、字段名静态且引用已定义。
- [ ] **静态类型检查**：句柄 bytes/text 类型匹配，不匹配即拒（如 `concat` 混接 bytes 与 text）。
- [ ] **`hmac-sha256`/`hkdf` 的 key 必须是句柄引用**，字面量密钥一律拒（manifest 已签名分发 = 公开）。
- [ ] **静态复杂度限额**：嵌套深度 ≤16、节点数 ≤64、每 op 参数 ≤8（§0.1）。
- [ ] **`regex` 语法白名单**：禁嵌套量词、禁 lookbehind；模式串静态校验。
- [ ] 校验 declarative-only 与信任门：**能力判定挂 `devSideload` 档本身**，🔒 **不得写成「非 official 即放行」的否定式**（ADR-023 §2.6 防扩散条款）。
- [ ] 为缺失值、凭证派生值、回显值、越界注入、循环和非法 op 增加安全负例。
- [ ] 新增安全负例：类型不匹配、字面量 key、超深度/超节点/超参数、非法 regex 语法。
- [ ] 运行 validator smoke、schema golden 和全量 adapter validate。

## 4. Server runtime / broker 🔒

- [ ] 在现有 declarative 代取 seam 上实现请求依赖拓扑排序；无依赖请求可并发。
- [ ] 在脱敏前完成 broker 侧提取，句柄仅存在于 broker 内部。
- [ ] 实现封闭 compute op；不得引入任意脚本执行或新运行时依赖。
- [ ] **运行时限额执行**：单句柄 64 KB、全 DAG 句柄总预算 4 MB，超出 fail-closed（§0.1）。
- [ ] **`regex` 回溯步数预算**：超预算抛 fail-closed 错误（非超时）；两端步数计数一致。
- [ ] **`now` 由既有 `AdapterRunInput.nowMs` 喂入定值**（复用现有固定 `NOW` golden 约定），不得读真实时钟。
- [ ] **逐 op 形式化语义表 + 每 op ≥1 条双端 golden**：重点 `substring` 越界（JS 钳制 vs Dart 抛）、`urlencode` 变体（component/query/RFC3986，空格 `%20` vs `+`）。
- [ ] 复用现有 credential injection seam，并对注入请求执行 fail-closed 校验。
- [ ] 剥离响应中的凭证、注入值回显和重定向中间 token（🔒 **回显剥离为 MVP 必做项**，ADR-023 §2.5）。
- [ ] **错误只进宿主日志 / 用户诊断，绝不回流 adapter**：adapter 侧观测到的须是整条 capability 失败，与正常失败路径不可区分。
- [ ] 增加双端 golden、拓扑/超时/请求数/响应大小/错误路径测试。
- [ ] 完成安全清单和人工 runtime/broker 审阅后才可合并。

## 5. Client runtime 🔒

- [ ] 在 `client/lib/core/declarative_host.dart` 实现与 server 对称的 DAG 执行。
- [ ] 保证客户端 QuickJS adapter 仍只执行末端同步解析，不接触句柄或中间响应。
- [ ] 对凭证 scope、静态注入位置、请求上限、超时和响应脱敏保持 fail-closed。
- [ ] **与 server 对称实现**：§0.1 全部限额、`regex` 步数预算、句柄类型语义、`now` 定值喂入、错误只进宿主日志。
- [ ] 增加 Dart golden，与 server 对同一 fixture 产出完全一致（含逐 op 语义 golden）。
- [ ] 增加客户端安全负例并完成人工 runtime 审阅。

## 6. Adapter 迁移

- [ ] 选定一个固定拓扑、纯提取/封闭计算的 imperative capability 作为试点，记录迁移前后请求图。
- [ ] 将试点迁为 declarative `bind/compute/inject`，业务解析代码保持末端纯解析。
- [ ] 为试点补脱敏 replay fixture、标准 schema golden 和双端回归。
- [ ] 仅在试点通过人工安全审阅后，逐个迁移其它 capability。
- [ ] 对仍保留 imperative 的 capability 写明动态拓扑或不可枚举计算理由。

## 7. 收尾与发布门槛

- [ ] contract、validator、server、client、adapter 的测试全通过。
- [ ] server/client golden 双跑一致。
- [ ] 全仓检查旧平铺代取假设、开放的句柄值、非静态注入和任意 compute。
- [ ] 检查 release 下 sideload 门禁未被放宽，公网服务端仍无凭证存储。
- [ ] 人工安全签收、owner 签收 ADR-023 §5 决策和本清单后，才标记迁移完成。

## 8. 建议实施顺序

1. 完成 §0 决策并更新 ADR-023。
2. 先做 validator/schema 设计和安全负例，不接 runtime。
3. 实现 server broker 与 golden，再实现 client 对称路径。
4. 以一个 adapter capability 试点迁移。
5. 通过人工安全审阅后扩大迁移范围并完成收尾。

*本清单由 ADR-023 落地使用；所有条目完成且人工签收后，才可称 ADR-023 已落地。*
