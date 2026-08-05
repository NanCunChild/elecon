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
| 深度（B2） | 平台 parser **前**做线性、非递归的括号计深，超 `MAX_JSON_DEPTH = 512` → `capture_too_deep`；防极深嵌套在递归 parser 内栈溢出且**两端栈深上限不同导致分叉** |

区间定位用 code unit、限额用 UTF-8 字节：实现与注释必须写清，避免误当成「字节偏移剪接」。

### 1.4 两类扫描器与边界（B1-b / B2 · owner 钉死 2026-08-04）

引擎里有**两个独立扫描器**，职责与运行时机必须区分：

1. **深度预扫描器（B2，`assertJsonDepth`）**：线性、非递归，**在平台 parser 之前**运行；只计括号（尊重字符串、`\\` 跳两位），超 `MAX_JSON_DEPTH=512` 即 `capture_too_deep`。目的是在递归 parser 之前把深度炸弹挡掉（跨端栈深分叉 + DoS）。
2. **JSON 定位扫描器（B1，`scanString`/`scanIndexedValue`/`lookupJsonSpan`/…）**：**仅在平台 parser 已判合法的 body 上运行**；不试图比 parser 更宽容；与 parser 的**任何结构分歧一律 fail-closed**，唯一**有意**分歧是重复键（parser 后键胜、扫描器记录后由索引查询抛 `capture_duplicate_key`，见 §2）。

**错误优先级（finding 5）**：`assertJson` 内先跑深度预扫描、再跑平台 parser。故**超深且畸形**的 body → `capture_too_deep`（**优先于** `capture_not_json`）。golden `json_too_deep_before_malformed_priority` 锁定此优先级。

**度量口径**：**下标 = UTF-16 code unit，限额 = UTF-8 byte**，二者不得混用。更改任一口径 **须重签 B1–B3**（golden 双跑为唯一防回归）。

**深度阈值**：`MAX_JSON_DEPTH=512` 两端常量必须一致；由 golden 边界对锁定——`json_depth_512_ok`（512 层成功，兼证两端 parser 在 512 层安全）+ `json_too_deep_fail_closed`（513 层拒），防 `>512` 被误改为 `>=512`。极少数合法超深载荷不在覆盖目标内——寄希望于中转 / 合法 relay 方案。

**单次稀疏索引（finding 1 · 方案 B，2026-08-05 实现待人工复签）**：所有 JSON rule 的 token 路径先合并为前缀树；平台 parser 判合法后，定位扫描器只线性经过 body 一次，仅保留规则可达节点的源码 span、类型和导航对象层的首个重复键。Capture / Project 随后只查索引，并一次顺序拼接投影响应，不再重扫或按规则整包复制，复杂度收敛为 O(body + Σ path depth + rules log rules)。索引增量空间最坏为 O(规则可达节点 + 所有活跃导航层 sibling keys)，可达 O(body)；平台 parser 还会短暂构造完整 DOM，这是 ADR-026 B1「先整体校验」基线的一部分，不得误称整体空间仅与规则数相关。`MAX_SCAN_BUDGET = 16 MiB` 保留为「一次合法性校验计量 + 一次索引扫描计量」的不变量护栏；在既有 8 MiB UTF-8 body 上通常不可达，不替代 body/rule 上限。共享生成式向量 `transaction_single_index_reused` 用 80,000 键 × 64 rules（契约上限）钉死旧方案 A 会拒绝、方案 B 应成功的边界。🔒 本增量改写 B1 扫描器，须 owner 逐行复签后方可继承 B1 签收状态；owner 复签时须同时评估 8 MiB 平台 DOM + 活跃 key 集合的移动端峰值。

**数组下标安全整数（finding 2）**：下标须为安全整数（≤ 2^53−1）。超界时 JS `Number` 丢精、Dart `int.parse` 抛 → 两端漂移（TS `capture_not_found` vs Dart 逃逸非 MaskerException）。故两端 tokenizer 与 validator（`validJsonPath` / RM14）统一在越界时判为**不支持语法**（runtime `capture_bad_jsonpath`、发布期 `RM14_bad_jsonpath`）。golden `json_array_index_unsafe_fail_closed` + validator `bad-jsonpath-unsafe-index` 锁定。

### 1.5 命中值在 body 别处回显：**作者责任**（B1-a · owner 拍板 2026-08-04）

Masker 只掩码**声明路径命中的那一处标量**。若同一凭证密文在同一响应的**别处回显**（未被任一规则声明），引擎**不做全 body sweep**，该副本会随投影响应交付。owner 决议：**落作者责任，不以运行期全 body 扫描追求「完美」**。理由：

1. **不能以完美哲学要求工程问题**：运行期全 body 子串扫描对**短密文必然误报**（`"1"` / `"true"` 命中业务数据 → 整条 capability 假失败），对大 body 有成本。
2. **official adapter 的可靠性链可信**：命中值回显属畸形/低概率，且 official adapter 经**静态扫描 + 动态夹具 + 人工 / AI 辅助复审**;责任落作者可接受。
3. **纵深仍在**：即便偶发回显，经审查的 adapter 也几乎无法利用该凭证（能力面受限、无凭证值直取通道）。

作者纪律：**每个回显位置各写一条 `redact` 规则**。发布前主捕获 = D3 `review/` observation→replay 夹具 + D6 `check-adapters.mjs` 门。此边界须写入贡献规范（D8）。

> **方案 A 基线已签收、方案 B 待复签；补偿控制在途（finding 6）**：B1-a 的**决议**已定（不做运行期 sweep）；2026-08-05 完成的是方案 A 扫描器人工签收，后续方案 B 索引重构须重新逐行复签。作者侧补偿控制 D3 / D6 / D8 尚未落地，仍作为 adapter 发布闭环的独立阻塞。

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

对象扫描时用集合记录**已见键**（键比较 = 反转义后字符串相等），索引记录首个重复键；规则查询经过该对象层时抛 `capture_duplicate_key`。作用域严格限「路径导航所经过的对象层级」：未被导航的兄弟嵌套对象内部重复键**不**检测（见 golden `json_unnavigated_sibling_duplicate_ignored`）。

**已落地（2026-07-31；2026-08-05 方案 B 改为索引等价实现）**：两端扫描完整个导航对象层，覆盖「命中在前、重复在后」；方案 B 把重复键结构信息留在稀疏索引，由查询按规则顺序拒绝。golden 覆盖：`json_duplicate_target_key_fail_closed`（`{"a":1,"a":2}` + `$.a`）、`json_duplicate_sibling_key_fail_closed`（同层非目标键重复）、`json_duplicate_nested_navigated_fail_closed`（导航所经嵌套层重复）、`json_unnavigated_sibling_duplicate_ignored`（未导航兄弟内部重复 → 正常返回）、transaction `fail_closed_duplicate_key_nothing_delivered`；两端双跑一致。

---

## 3. 诊断回显：挂 ADR-024 **DEV** profile，非传统 debug flag

### 3.1 决议

「至少能在开发产物中溯源 Masker 失败原因」**预备在 [ADR-024](../adr/adr_024_build_profile_trust.md) 落地之后**，挂在信任 profile **`DEV`（含侧载 / `ELECON_TRUST_PROFILE` 等编译期 flag 所标定的开发 profile）** 上，**不**绑定传统 `kDebugMode` / `kReleaseMode` 优化等级。

**稳定契约（B5 · owner 拍板 2026-08-04）**：对外/对宿主诊断的稳定契约是 **§3.3 结构化字段**（`code` / `ruleId` / `source` / `path`\|`headerName` / 重复键 `key`），**不是** message 文案；DEPLOY 丢弃人读 message，只留稳定 `code`。**发射实现挂 C1**——由 firewall 上层 catch 在 DEV profile 决定写哪些字段（`ruleId` / `path` 等上下文只在规则层可得）；本纯引擎只负责**携带稳定 `code`**、永不在 message 放原值。

> **引擎携带 `key`（finding 3 修复 2026-08-04）**：重复 sibling 键名 `key` 只在**引擎层**可得，故稀疏索引保留该结构字段，`MaskerError` / `MaskerException` 在 `capture_duplicate_key` 时携带 `detail.key` / `key`（golden `errorKey` 双端校验）。C1 上层再补 `ruleId` / `path`。字段**只含键名**，绝不含候选值 / 原值。

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
| 手写扫描器 + 稀疏索引 + 剪接 | 纯引擎（方案 B 已实现、待人工复签） | checklist **B1**；golden 双跑 |
| 重复键 fail-closed + golden | **已落地并签收**（纯引擎增量，2026-08-05） | checklist **B1/B6**；码 `capture_duplicate_key`；结构化 `key` + 双端 golden；owner 逐行人审完成 |
| 扫描器边界钉死（B1-b） | **已落地**（文档 §1.4，2026-08-04） | 度量口径不得混用 / 分歧即 fail-closed；改口径重签 B1–B3 |
| 回显作者责任（B1-a） | **决议已落**（文档 §1.5，2026-08-04；不做运行期 sweep） | 作者写 redact + D3/D6 发布前捕获；D8 补贡献规范 |
| 深度预检（B2） | **已落地**（纯引擎增量，2026-08-04） | 码 `capture_too_deep`；`MAX_JSON_DEPTH=512`；golden `json_too_deep_fail_closed` 两端双跑绿 |
| 漂移 / 转义 golden（B3） | **已落地**（golden 增量，2026-08-04） | 非 BMP 前置下标 parity、代理对、末尾反斜杠、转义引号；两端双跑绿 |
| DEV 结构诊断 | **ADR-024 落地之后**接线（契约=§3.3 结构字段，B5 已定） | checklist **B5** + C1 上层 catch 扫；DEPLOY 无详细路径泄漏 |
| 改树方案 | **不做** | 本文 §1.2 |

实现 PR 须声明：遵循本文 §1–§3 与 ADR-026 §2.5/§2.8；重复键不引入选择器；诊断字段符合 §3.3 白名单。

---

## 5. 修订记录

| 日期 | 内容 |
|---|---|
| 2026-07-31 | 初版：手写扫描器 + golden；重复键 fail-closed；诊断挂 ADR-024 DEV profile（非传统 debug flag）。 |
| 2026-08-04 | owner 拍板 B 组收尾：B1-a 回显落作者责任（不做运行期 sweep，§1.5）；B1-b 扫描器边界钉死（§1.4）；B2 深度预检 `capture_too_deep`（`MAX_JSON_DEPTH=512`）落地；B3 漂移/转义 golden 落地；B5 诊断稳定契约 = §3.3 结构字段（发射挂 C1）。B4 header 大小写歧义**待 owner 讨论**（两端生产传输层均归一化 → `capture_ambiguous` 为纵深，见签收清单）。 |
| 2026-08-04（外部评审后续） | B4 owner 定为**契约**（map 到 masker 前已归一，`capture_ambiguous` = belt-and-suspenders）。修 finding 2（数组下标安全整数 → tokenizer + validator RM14，§1.4）、finding 3（`capture_duplicate_key` 携带结构化 `key`，§3.1）、finding 4（补 `json_depth_512_ok` 锁 512/513 边界，§1.4）、finding 5（区分深度预扫描器 vs 定位扫描器 + 错误优先级，§1.4）、finding 6（B1-a 补偿控制 D3/D6/D8 未落地前不算关闭，§1.5）。**finding 1（High，CPU 放大）未解**——owner 待选「扫描预算 vs 结构索引」，B1 主签收阻塞（签收清单 §B「B1 唯一未决」）。 |
| 2026-08-05 | finding 1 owner 选**方案 A 确定性总扫描预算**（`MAX_SCAN_BUDGET=16 MiB` 累计 code unit，跨 Capture/Project 单计数器，超即 `capture_budget_exceeded`），两端代码 + 生成式双跑测试落地（§1.4）。**方案 B（建索引复用，抬高天花板）列待做**。B1 剩承重扫描器逐行人审。 |
| 2026-08-05（最终签收） | owner 完成 B1–B6 人工检查；B1 扫描/剪接与方案 A 预算成为当前基线。共享 golden 增 `generatedLimits`，双端生成式覆盖 header/body/capture-value/事务扫描预算四类超限，Masker 共 50 例全绿。D3/D6/D8、C1 诊断发射与方案 B 保留为独立后续项。 |
| 2026-08-05（方案 B） | 定位器改为按全部 rule 路径一次构造稀疏源码索引，Capture / Project 复用，并一次拼接投影结果；保留导航层重复键、源码 span、错误顺序与 16 MiB 计量护栏。生成式事务向量由预算拒绝改为索引复用成功，新增共享前缀/嵌套数组与跨分支错误优先级。双端 52 例全绿；🔒 新扫描器待 owner 逐行复签。 |
