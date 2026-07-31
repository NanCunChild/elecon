# Response Masker 安全签收与收尾清单（ADR-026）

> 状态：**纯 Capture/Project 引擎（工程说明 §9.2 step 3）已落地并双端双跑绿**；本清单登记 owner 已拍板的实施决议、待逐行复审的承重代码、后续阶段收尾项，以及 elecon-adapters 侧改动。
> 🔒 触红线 #1/#5/#6/#10。凭证 / Broker / 契约 / 签名路径的实现与测试须人工主导，AI 不得独自闭环（AGENTS.md §1）。

已落地文件：`server/src/runtime/broker/response-masker.ts`、`client/lib/core/broker/response_masker.dart`、`contract/golden/broker/response-masker.json`（29 例）、两端 smoke/test。契约+validator（step 2）见 `contract/response-masker.schema.json`、`tools/src/validator/response-masker.ts`。

---

## 0. 已拍板实施决议（2026-07-31 owner 评审）

| 编号 | 决议 | 落实状态 |
|---|---|---|
| A1 | `redact` = **仅投影、不托管、不注入**；用例应少于 `handle`；规范推荐 adapter 作者「能 redact 就不 handle」以减少接触面 | 引擎行为已符合；ADR §2.3 已记推荐；**待落入 adapter 贡献规范（见 D8）** |
| A2 | 只剥「因 body 改写而失真」的实体头（`Content-Length`/`Content-Encoding`/`ETag`），保留 `Content-Type`；**仅 header 删除、body 未改写时不 strip** | 引擎已实现（strip 仅在有 json 改写时触发）；golden 已含正反例；ADR §2.8 已记 |
| A3 | Masker 只在**传输层解码后的 UTF-8 明文** body 上运行，**绝不猜测编码**；非法 / 非 UTF-8 在传输层→Broker 边界 **fail-closed 拒交付** | 已写入 ADR §2.8 与 `TransportResponse.body` 注释、两端引擎头注释；**运行期 fail-closed 由 firewall 落实（见 C1）** |
| A4 | sentinel 固定为 `__ELECON_MASKED__`（不再是「建议」） | 引擎常量 + golden + ADR §2.8 已定死 |
| A5 | capture **不做数值语义，只做区间文本**（数字/布尔取源码字面量、字符串仅反转义），凭证逐字节保真；接受与 dataflow 数值策略的有意分歧 | 引擎已实现；两端头注释已记；**本行即安全清单声明** |
| A6 | 接受「单响应单持久 credential」由 validator(RM15)/firewall 分层保证；接线时（C1/C2）加运行期 assert `captured.length ≤ 1` | **待 C1/C2 落实**（自然位置：`applyResponseMasker` 或 firewall 提交前） |
| B1a | JSON body：**手写源码定位 + 按位剪接**，不改树重序列化；漂移靠共享 golden（详文 [`response_masker_json_locator.md`](./response_masker_json_locator.md) §1） | 引擎已采用剪接；**B1 人审 + golden 补强仍待** |
| B1b | **重复 JSON 键 fail-closed**（码 `capture_duplicate_key`）；无 first/last、不重命名消歧；责任在学校侧畸形载荷（同文 §2） | **引擎已实现**（两端 `navigate` 扫完整层 + seen 集合；作用域限「导航所经对象层」，未导航兄弟嵌套内部重复键不检测）；golden 4 例（目标键/兄弟键/嵌套导航层重复 fail-closed + 未导航兄弟重复忽略）+ transaction 1 例，两端双跑绿；**B1 逐行人审仍待** |
| B1c | 开发者**结构**诊断（码 / ruleId / path·header 名 / 重复 key 名）挂 **ADR-024 DEV profile**，非 `kDebugMode`；DEPLOY 仅稳定错误码级；永不回显原值（同文 §3） | **ADR-024 落地后接线**；ADR §2.4 已记 |

---

## B. 待逐行详细复审的承重代码（合并前必须人工过）

按风险从高到低：

- [ ] **B1 手写 JSON 定位扫描器**（最高优先）：两端 `scanString`/`scanLiteral`/`scanContainer`/`navigate`/`spanScalarValue`。决议见 [`response_masker_json_locator.md`](./response_masker_json_locator.md) §1——剪接保留、不改树；重点：转义（`\\` 跳两位）、未闭合/畸形 fail-closed、键比较、数组越界、**重复键 → `capture_duplicate_key`（§2，无 first/last；已实现，扫完整层 + seen 集合，作用域限导航所经对象层）**。
- [ ] **B2 「先整体校验再扫描」**：`JSON.parse`/`jsonDecode` 校验后再扫描；确认两端在扫描器所依赖的语法边界一致（重复键与 §B1 同为 fail-closed、前导零、尾随内容）。
- [ ] **B3 字符串反转义**：以平台 JSON 反转义单个 token；验 `\uXXXX`、代理对（非 BMP）两端一致——牵动 UTF-16 码元下标假设。
- [ ] **B4 header 大小写 / 歧义**：大小写不敏感匹配，多种大小写并存判 `capture_ambiguous`。
- [ ] **B5 日志 / 诊断纪律**：`capture_*` / `project_overlap` / `capture_duplicate_key` 全 fail-closed；消息**不含原值/命中片段/敏感 URL**（ADR §2.4）。**结构溯源**（码、ruleId、path/header 名、重复 key 名）预备挂 **ADR-024 DEV profile**，非 `kDebugMode`（[`response_masker_json_locator.md`](./response_masker_json_locator.md) §3）；DEPLOY 仅稳定错误码级。C1 接线后扫上层 catch / 遥测。
- [ ] **B6 golden 覆盖补强**（建议补例）：**重复 JSON 键 fail-closed（P0）**、非 BMP/代理对剪接（P0）、超大 header/body/收割值触限、CRLF body、深层嵌套数组、`Content-Type` 带 charset。

---

## C. 后续阶段收尾（step 4→9，均须人工主导）

- [ ] **C0 前置：修 ADR-023 源响应投影缺口**（ADR §3）：「中间值从不进 adapter」叙述与「源响应仍交付」之间有缺口，step 5 前必须人工修订并测试。
- [ ] **C1 统一 delivery firewall（step 4）**：证明 declarative / imperative / actuator 三入口不可绕过；生产侧无直接构造 adapter-visible 响应的旁路。**并入 A3**：传输层→Broker 边界对非法 / 非 UTF-8 body fail-closed。**并入 A6**：提交前 assert `captured.length ≤ 1`。
- [ ] **C2 Commit 接线（step 5）**：Credential Store 原子提交（§2.4 单持久 ref + generation swap + 崩溃语义）；ADR-023 opaque handle staging；handle 源投影（§3：同次 raw 提取执行 bind 一次，产出 staged handle + 投影响应，不重复计量）。
- [ ] **C3 host/version gate**：落地后移除 validator `RM0_host_gate_unavailable` 阻断；同步改 **ADR-018** bundle 内容说明（`masker.json` 为受版本门约束的可选签名运行时文件）；旧 host 遇新 bundle 拒载。
- [ ] **C4 §7.4 尚缺项**：charset / 压缩 / 非法编码语义（呼应 A3，多数属传输层）由 golden 钉死。
- [ ] **C5 §10 发布/吊销门**：observation→rule→destination→replay 闭合；raw canary 不出现在 delivered fixture；policy diff / 删除 waiver；旧漏洞版本 revocation / `minVersion`；review fixtures 不进 bundle；签名台账加 `maskerDigest`。
- [ ] **C6 §2.6 adapter-side 提取 scanner**：token/session/cookie、认证 header、跨请求值传递、高危正则作**人工审查触发器**（非自动裁定）。
- [ ] **C7 §12 人工签收**：schema+失败语义、firewall 无旁路、Store/handle 生命周期、golden+raw-to-adapter replay、无真实凭证/学生数据、发布/吊销/回退演练。

---

## D. elecon-adapters 侧改动

> adapters 在 `ncc-devlab`、合并后自动镜像；客户端按需拉取（`adapters.pin` + `fetch-adapters.sh`）；per-capability 门 `check-adapters.mjs` 仍 DRAFT。

- [ ] **D1 bundle 内新增 `masker.json`**（schema v1，adapter 根，进 digest + 官方签名）；确保按需拉取/镜像链路一并带上。
- [ ] **D2 manifest 声明 credential ref**：`credential` 目标引用的 ref 须在 manifest 已声明（validator RM8），形态依赖 **ADR-029**。**ADR-029 已接受（2026-07-31）**，§2.1 命名 header **契约 + validator（CH1–CH3）+ Broker 注入（inject-policy/assemble 两端 + 双端 golden）全部已落地**，`headerName` 可用（缺省 Authorization），注入 / adapter 同名头剥除 / 响应回显脱敏均双跑绿（🔒 待人工逐行审）。credential 目标形态解锁。**待做**：Masker Commit → Credential Store 写入该 ref（C2）与 masker→注入闭环；`aircon-session` 等 ref 声明随首例（D7）落。
- [ ] **D3 审查材料 `review/`**（`fixtures/raw`、`fixtures/delivered`、`security-observations.json`）放仓库但**不进发布 bundle**；CI 校验不被打包。
- [ ] **D4 迁移盘点（§9.1）**：逐个扫 adapter/probe 对 header/body/URL 的正则/JSONPath/切片提取 `token/session/code/openid/client_id`、cookie value 来源（`setEphemeralCookie`）、跨请求值流；逐项人工分类，不按变量名批改。
- [ ] **D5 迁移改写**：命中值改走 Broker credential 注入或 ADR-023 handle；删除 adapter 自行读取/保存/正则/日志/手工拼请求。
- [ ] **D6 `check-adapters.mjs` 扩门**：把 masker 校验与 observation→rule→replay 闭合纳入 adapters 侧 CI。
- [ ] **D7 首例：聚好联空调**（命名 header 注入小闭环），**必须虚构 token/设备 ID**，且**受 ADR-029/030 接受约束**（均仍 Proposed）。
- [ ] **D8 贡献规范补 A1 推荐**：明文写入 adapter 作者指南——「能 `redact` 就不 `handle`」，减少核心接触面。
