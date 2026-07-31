# Response Masker · JSON 定位扫描器与重复键 / DEV 诊断决议

> **状态**：owner 拍板（2026-07-31）· 实现约束（非独立 ADR）。  
> **归属**：[`adr_026_response_masker.md`](../adr/adr_026_response_masker.md) §2.5 / §2.8。  
> **相关**：[`response_masker_plan.md`](./response_masker_plan.md) §6、[`response_masker_signoff_checklist.md`](./response_masker_signoff_checklist.md) B1/B2/B5/B6、[`adr_024_build_profile_trust.md`](../adr/adr_024_build_profile_trust.md)。  
> 🔒 承重路径（红线 #1）：扫描器、重复键语义与诊断内容均须人工 + 安全清单复核，AI 不得独自闭环。

本文固定 **B1 手写 JSON 定位扫描器** 的工程取舍、**重复 JSON 键** 的 fail-closed 语义，以及 **诊断回显** 与 ADR-024 信任 profile 的绑定。  
契约级决策仍以 ADR-026 为准；本文是可执行决议，供实现与签收对照。

---

## 1. 手写源码定位 + 按位剪接（保留）

### 1.1 决议

Capture / Project 对 JSON body 使用**手写、封闭的源码定位扫描器**（两端各一份：TS `response-masker.ts` / Dart `response_masker.dart`）：

- 在**已通过整体 JSON 合法性校验**的 body 上，沿受限 JSONPath 定位**唯一**标量的源码区间；
- Project 按区间**剪接**为固定 sentinel（`__ELECON_MASKED__`），**不**走「解析 → 改树 → 重序列化」。

跨端字节一致性由共享 golden（`contract/golden/broker/response-masker.json`）钉死（ADR-001 §8）。

### 1.2 为何不改树重序列化

Masker **交付整段 adapter-visible body**，要求比 ADR-023 dataflow 的「只抽取标量进 handle」更严：

| 面 | 改树 + `JSON.stringify` / `jsonEncode` |
|---|---|
| 大整数 | JS `JSON.parse` 对超 `2^53−1` 整数舍入进 double；Dart 可保 64 位——dataflow 已对超安全整数 fail-closed，见 `declarative_dataflow_ops.md` |
| 数字 / 浮点 / `-0` / 科学计数 | 两端序列化格式未统一契约 |
| 空白、键序、转义 | 学校 body 非规范 minify 时，重序列化常整包重排 |
| A5 凭证保真 | Capture 对数字/布尔取**源码字面量**；改树会破坏该语义 |

自研「规范化 JSON 编码器」两端共用的成本 ≥ 手写定位器，且仍难满足源码保真。故 **不以改树替代剪接**。

### 1.3 扫描器须钉死的行为（golden + 人审）

| 点 | 要求 |
|---|---|
| 转义 | `scanString`：`\\` 跳两位（只负责定位）；`\uXXXX` / 代理对等由 token 级平台 `JSON.parse` / `jsonDecode` 反转义 |
| 畸形 | 先整体 `JSON.parse` / `jsonDecode`；扫描期未闭合等 → `capture_not_json` |
| 路径 | 封闭子集与 dataflow 同口径：`$`、`.key`、`['key']`、`["key"]`、`[n]` |
| 下标 | 字符串 **UTF-16 code unit** 区间（JS/Dart 一致）；输入/收割**限额**用 UTF-8 字节（对齐 dataflow） |
| 非标量 | 对象 / 数组 / `null` → `capture_not_scalar` |
| 缺失 / 越界 | `capture_not_found` |

区间定位用 code unit、限额用 UTF-8 字节：实现与注释必须写清，避免误当成「字节偏移剪接」。

---

## 2. 重复 JSON 键：fail-closed（无选择器）

### 2.1 决议

在 JSONPath 导航所经过的对象层级上，若源码中出现**同名键重复**（同一对象内 key 字符串反转义后相等且出现 ≥2 次）：

- **一律 fail-closed**；
- 错误码：`capture_duplicate_key`（**已落地为独立码**，2026-07-31；便于 DEV 溯源，golden 与诊断文案可区分）；
- **不**提供 first / last 开关；
- **不**对重复键重命名（如 `token_{uuid}`）或改写 body 结构以「消歧」。

Capture 与 Project 共用同一导航逻辑，故重复键时**不得**完成收割，也**不得**交付半投影 body。

### 2.2 责任边界

RFC / 常见解析器对重复键为 implementation-defined（先键、后键或报错）。合法业务依赖重复键的学校 API 视为畸形载荷。

- **责任在学校侧（或 adapter 应对该端点的策略/热更）**，不在 Broker 用选择器「猜对」某一键。
- 与 header 多形态并存 → `capture_ambiguous` 同构：路径语义要求 **exactly:1**，歧义即关。
- 字段漂移本就要求 adapter 代码与 `masker.json` 同 bundle 原子更新（ADR-026 §2.5）；重复键怪 body 使 capability 失败是正确产品行为。

### 2.3 明确否决的方案

| 方案 | 否决理由 |
|---|---|
| `first` / `last` 配置 | 扩配置面与 golden 矩阵；与 fail-closed 哲学冲突；与 dataflow 对象语义易再分叉 |
| `token_{uuid}` 等重命名 | 非确定性砸双跑；改业务结构；把歧义推给 adapter；工程不可行 |
| 静默采用源码先键 | 与平台 `JSON.parse` 常见后键语义裂缝；无 golden 时 silent 错——应用 fail-closed 闭合，而非钉「先键」 |

### 2.4 实现要点（待接线）

对象扫描时用集合记录**已见键**（键比较 = 反转义后字符串相等）；再见同一键 → 抛 `capture_duplicate_key`。作用域严格限「路径导航所经过的对象层级」：未被导航的兄弟嵌套对象内部重复键**不**检测（见 golden `json_unnavigated_sibling_duplicate_ignored`）。

**已落地（2026-07-31）**：两端 `navigate` 改为扫完整个对象层再决定（命中键记录值起点后继续扫，覆盖「命中在前、重复在后」）。golden 覆盖：`json_duplicate_target_key_fail_closed`（`{"a":1,"a":2}` + `$.a`）、`json_duplicate_sibling_key_fail_closed`（同层非目标键重复）、`json_duplicate_nested_navigated_fail_closed`（导航所经嵌套层重复）、`json_unnavigated_sibling_duplicate_ignored`（未导航兄弟内部重复 → 正常返回）、transaction `fail_closed_duplicate_key_nothing_delivered`；两端双跑一致。

---

## 3. 诊断回显：挂 ADR-024 **DEV** profile，非传统 debug flag

### 3.1 决议

「至少能在开发产物中溯源 Masker 失败原因」**预备在 [ADR-024](../adr/adr_024_build_profile_trust.md) 落地之后**，挂在信任 profile **`DEV`（含侧载 / `ELECON_TRUST_PROFILE` 等编译期 flag 所标定的开发 profile）** 上，**不**绑定传统 `kDebugMode` / `kReleaseMode` 优化等级。

依据（与 ADR-024 一致）：

- **优化 ⊥ 信任**：社区开发者可在 release 级优化下开发 adapter；侧载与开发者诊断能力由 **信任 profile** 决定，而非「是否卡顿的 debug 构建」。
- **fail-closed 默认 DEPLOY**：flag 缺失 / 拼错 → DEPLOY；DEPLOY 产物内开发者级 Masker 诊断路径应可 tree-shake 或等价不可达（与侧载入口同构的编译期纪律）。
- 在 ADR-024 完全接线前：实现可暂用现有 dev/debug 通道做**本地**对照，但**文档与后续接线目标**以 DEV profile 为准，避免把长期语义钉死在 `kDebugMode` 上。

### 3.2 分层：结构定位 vs 材料内容

| 构建 | 宿主诊断（DevLog / 本地开发者通道等） | 进入 adapter envelope |
|---|---|---|
| **DEV profile** | **允许**稳定错误码 + 规则 id + JSONPath / header **名** +（重复键时）**key 名** + capability / 请求上下文 id | **禁止**任何原值、命中片段、可推导密钥材料；错误对 adapter 仍为整条 capability 失败 |
| **DEPLOY profile** | 仅稳定错误码或统一 `masker_failed` 级摘要；**不得**依赖「详细 message 含 path」才能安全 | 同上；adapter **永不**见原值或定位细节中的秘密 |

任何 profile 下均适用 ADR-026 §2.4：

> 日志不得包含原值、命中片段、原始 body、带敏感 query 的 URL 或可推导凭证长度的信息。

DEV 多出的是**结构定位**（哪个 rule / 哪条 path / 哪个重复 key），不是**材料内容**。

### 3.3 DEV 诊断字段白名单（建议）

允许写入宿主诊断（DEV）：

- `code`：`capture_duplicate_key` / `capture_not_found` / `capture_ambiguous` / `capture_not_scalar` / `capture_not_json` / `project_overlap` / …
- `ruleId`（策略规则 id）
- `source`：`header` | `json`（及将来封闭源）
- `path` 或 `headerName`（**策略声明名**，非响应值）
- 重复键场景：`key`（键名字符串）及可选 `occurrenceHint`（如 `>=2`，**不含**候选值）
- capability id / request key（非敏感业务 id）

禁止（任何 profile）：

- capture 得到的字符串/数字原值或子串；
- 投影前 body 片段；
- cookie / token / Authorization 原文；
- 带敏感 query/fragment 的完整 URL；
- 仅用于侧信道的精确字节长度（若与 §2.4「可推导长度」冲突，DEV 亦省略）。

### 3.4 与现有日志文档的关系

[`cross_end_logging.md`](./cross_end_logging.md) 仍约束 client/campus 通用脱敏。  
Masker 诊断在 **DEV profile** 下扩展「结构字段」时，须：

1. 不经公网 / telemetry 默认同步（与 DevLog 纪律一致）；
2. 不把详细诊断塞进 adapter 可见错误；
3. ADR-024 落地后，把「详细 Masker 诊断」从任何 `kDebugMode` 临时挂钩迁到 **DEV profile 编译期门**。

---

## 4. 落地与签收对照

| 项 | 阶段 | 签收点 |
|---|---|---|
| 手写扫描器 + 剪接 | 纯引擎（已有） | checklist **B1**；golden 双跑 |
| 重复键 fail-closed + golden | **已落地**（纯引擎增量，2026-07-31） | checklist **B1/B6**；码 `capture_duplicate_key`；golden 4+1 例两端双跑绿；B1 逐行人审仍待 |
| DEV 结构诊断 | **ADR-024 落地之后**接线 | checklist **B5** + C1 上层 catch 扫；DEPLOY 无详细路径泄漏 |
| 改树方案 | **不做** | 本文 §1.2 |

实现 PR 须声明：遵循本文 §1–§3 与 ADR-026 §2.5/§2.8；重复键不引入选择器；诊断字段符合 §3.3 白名单。

---

## 5. 修订记录

| 日期 | 内容 |
|---|---|
| 2026-07-31 | 初版：手写扫描器 + golden；重复键 fail-closed；诊断挂 ADR-024 DEV profile（非传统 debug flag）。 |
