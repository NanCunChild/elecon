# Response Masker 安全签收与收尾清单（ADR-026）

> 状态：**纯 Capture/Project 引擎（工程说明 §9.2 step 3）已落地并双端双跑绿**；方案 A 基线已签收，后续方案 B 单次稀疏索引重构已实现、**待 owner 重新逐行安全复签**。本清单同时登记后续阶段收尾项与 elecon-adapters 侧改动。
> 🔒 触红线 #1/#5/#6/#10。凭证 / Broker / 契约 / 签名路径的实现与测试须人工主导，AI 不得独自闭环（AGENTS.md §1）。

已落地文件：`server/src/runtime/broker/response-masker.ts`、`client/lib/core/broker/response_masker.dart`、`contract/golden/broker/response-masker.json`（52 例，含 3 个共享生成式超限向量 + 1 个索引复用向量）、两端 smoke/test。契约+validator（step 2）见 `contract/response-masker.schema.json`、`tools/src/validator/response-masker.ts`。**B2–B6 与 B1 方案 A 基线已由 owner 于 2026-08-05 签收；B1 方案 B 须复签**；C/D 组生产接线与发布控制仍独立阻塞。

---

## 0. 已拍板实施决议（2026-07-31 owner 评审）

| 编号 | 决议 | 落实状态 |
|---|---|---|
| A1 | `redact` = **仅投影、不托管、不注入**；用例应少于 `handle`；规范推荐 adapter 作者「能 redact 就不 handle」以减少接触面 | 引擎行为已符合；ADR §2.3 已记推荐；**待落入 adapter 贡献规范（见 D8）** |
| A2 | 只剥「因 body 改写而失真」的实体头（`Content-Length`/`Content-Encoding`/`ETag`），保留 `Content-Type`；**仅 header 删除、body 未改写时不 strip** | 引擎已实现（strip 仅在有 json 改写时触发）；golden 已含正反例；ADR §2.8 已记 |
| A3 | Masker 只在**传输层解码后的 UTF-8 明文** body 上运行，**绝不猜测编码**；非法 / 非 UTF-8 在传输层→Broker 边界 **fail-closed 拒交付** | 已写入 ADR §2.8/§2.10 与两端引擎头注释；**运行期已接入（2026-08-05，🔒 待人审）**：`transport/direct.ts` 按 charset + `fatal` UTF-8 解码产出 `TransportResponse.decodeOk`，`false`→firewall `body_not_plaintext` fail-closed（transport smoke 8/8、imperative A3 e2e 绿）。**待**：Dart transport 镜像 + charset golden |
| A4 | sentinel 固定为 `__ELECON_MASKED__`（不再是「建议」） | 引擎常量 + golden + ADR §2.8 已定死 |
| A5 | capture **不做数值语义，只做区间文本**（数字/布尔取源码字面量、字符串仅反转义），凭证逐字节保真；接受与 dataflow 数值策略的有意分歧 | 引擎已实现；两端头注释已记；**本行即安全清单声明** |
| A6 | 接受「单响应单持久 credential」由 validator(RM15)/firewall 分层保证；接线时（C1/C2）加运行期 assert `captured.length ≤ 1` | **待 C1/C2 落实**（自然位置：`applyResponseMasker` 或 firewall 提交前） |
| B1a | JSON body：**手写源码定位 + 按位剪接**，不改树重序列化；漂移靠共享 golden（详文 [`response_masker_json_locator.md`](./response_masker_json_locator.md) §1） | 引擎已采用剪接；**B1 人审 + golden 补强已完成（2026-08-05）** |
| B1b | **重复 JSON 键 fail-closed**（码 `capture_duplicate_key`）；无 first/last、不重命名消歧；责任在学校侧畸形载荷（同文 §2） | **语义已实现；方案 B 待复签**（两端单次扫描完整导航层、索引记录首个重复键、查询经过该层时拒绝；未导航兄弟嵌套内部重复键不检测）；golden 覆盖目标键/兄弟键/嵌套导航层/转义等价键 fail-closed、未导航兄弟重复忽略及 transaction 原子失败 |
| B1c | 开发者**结构**诊断（码 / ruleId / path·header 名 / 重复 key 名）挂 **ADR-024 DEV profile**，非 `kDebugMode`；DEPLOY 仅稳定错误码级；永不回显原值（同文 §3） | **ADR-024 落地后接线**；ADR §2.4 已记 |

---

## B. 承重代码逐行审查（owner 2026-08-05 已完成）

> **外部评审（2026-08-04）处置摘要**：
> - **finding 1（High，方案 B 已实现、待人工复签）**：旧定位器 O(body × path depth × rule count) CPU 放大；方案 B 将全部 rule 路径合并为前缀树，对 body 单次构造稀疏源码索引，Capture / Project 复用。`MAX_SCAN_BUDGET=16 MiB` 保留为一次校验 + 一次扫描的纵深上限。详见文末「B1 finding 1」。
> - **finding 2（Medium，已修）**：超安全整数数组下标两端漂移 → tokenizer + validator 统一安全整数上限（下 B3）。
> - **finding 3（Medium，已修）**：诊断稳定字段承诺含重复键 `key` 但实现丢弃 → `MaskerError`/`MaskerException` 加结构化 `key`（下 B5）。
> - **finding 4（Medium，已修）**：513-only 未锁 512 边界 → 补 `json_depth_512_ok`（下 B2）。
> - **finding 5（Low，已修）**：深度预扫描器 vs 定位扫描器顺序/错误优先级歧义 → 文档区分 + golden（下 B2）。
> - **finding 6（Low，已分轨）**：B1 纯引擎已签收；B1-a 补偿控制 D3/D6/D8 仍作为 adapter 发布闭环的独立阻塞（下 B1）。

按风险从高到低：

- [ ] **B1 手写 JSON 定位扫描器（方案 B 待 owner 复签）**：两端 `scanString`/`scanLiteral`/`scanContainer`/`scanIndexedValue`/`lookupJsonSpan`/`spanScalarValue`。决议见 [`response_masker_json_locator.md`](./response_masker_json_locator.md) §1——剪接保留、不改树；重点：转义（`\\` 跳两位）、未闭合/畸形 fail-closed、键比较、数组越界、**重复键 → `capture_duplicate_key`（§2，无 first/last；索引只在查询经过该对象层时拒绝）**。2026-08-05 的 `[x]` 仅覆盖方案 A 基线，本次结构重写后重开。
  - **B1-a 回显（owner 拍板 2026-08-04，决议已落）**：命中值在 body 别处回显 → **落作者责任，不做运行期全 body sweep**（理由：短密文误报 + 大 body 成本 vs official 可靠性链 + 纵深；详 json_locator §1.5）。作者为每个回显位置写 `redact`；发布前主捕获 = D3 replay + D6 门；**D8 须补贡献规范**。
  - **B1-b 扫描器边界（owner 钉死 2026-08-04，决议已落）**：扫描器仅在平台 parser 判合法的 body 上运行、分歧一律 fail-closed（唯一有意分歧=重复键）；**下标=UTF-16 code unit / 限额=UTF-8 byte 不得混用，改口径重签 B1–B3**（json_locator §1.4）。
  - **finding 6（补偿控制在途）**：B1 纯引擎已签收；B1-a 的作者侧 D3/D6/D8 仍是**发布控制阻塞**，不得据 B1 签收宣称 adapter 迁移/发布闭环已完成（json_locator §1.5）。
  - **finding 3（key 已携带）**：`capture_duplicate_key` 现携带结构化 `key`（重复 sibling 键名，golden `errorKey` 双端校验），使 B5 §3.3 承诺可兑现；字段只含键名、绝不含原值。
  - **当前结论**：方案 B 已移除 ×rules×2 重扫并通过共享 golden 双跑；方案 A 的 owner 签收不自动覆盖新扫描器，合并前须人工逐行复签。
- [x] **B2 深度预检 + 「先整体校验再扫描」**（owner 签收 2026-08-05）：`JSON.parse`/`jsonDecode` 校验后再定位扫描；确认两端语法边界一致（重复键 fail-closed、前导零、尾随内容、BOM）。
  - **B2 深度预检（owner 拍板 2026-08-04，2026-08-05 签收）**：`assertJson` 在平台 parser **前**做线性、非递归括号计深，超 `MAX_JSON_DEPTH=512` → `capture_too_deep`；消除深度炸弹在递归 parser 内的**跨端栈深分叉 + 低成本 DoS**。两端常量一致。
  - **finding 4（512 边界已锁）**：golden **边界对**——`json_depth_512_ok`（512 层成功，兼证两端 parser 512 层安全）+ `json_too_deep_fail_closed`（513 层拒），防 `>512` 被误改 `>=512`。
  - **finding 5（错误优先级已明）**：深度预扫描器（B2）先于 JSON 定位扫描器（B1）与平台 parser；**超深且畸形 → `capture_too_deep` 优先于 `capture_not_json`**。文档区分两类扫描器（json_locator §1.4），golden `json_too_deep_before_malformed_priority` + `json_brackets_in_string_not_counted`（串内 `{[` 不计深）双跑绿。
- [x] **B3 字符串反转义 / 下标漂移（owner 签收 2026-08-05）**：以平台 JSON 反转义单 token；UTF-16 码元下标假设是剪接承重前提。**golden 补齐**：`json_surrogate_pair_value`（代理对→非 BMP）、`json_trailing_backslash_value`（末尾 `\\`）、`json_escaped_quote_value`（`\"`）、project `replace_json_after_non_bmp_preserves_bytes`（**非 BMP 前置 → span 下标 parity**）、`replace_json_value_with_escaped_quote`；两端双跑绿。
  - **finding 2（数组下标安全整数已修）**：超 2^53−1 下标两端漂移（TS 丢精 `capture_not_found` vs Dart `int.parse` 抛逃逸）→ 两端 tokenizer + validator `validJsonPath` 统一判**不支持语法**（runtime `capture_bad_jsonpath` / 发布期 `RM14_bad_jsonpath`）。golden `json_array_index_unsafe_fail_closed` + validator `bad-jsonpath-unsafe-index` 双锁。
  - **孤立/错序代理对（建议 #8）**：**不入 shared golden**——lone high / lone low / 错序代理对的 capture 结果含孤立代理码元，无法在 UTF-8 golden 的 `expected` 里表达；归入 finding 1 之外的**差分/属性测试**（建议 #10）另行覆盖。
- [x] **B4 header 大小写 / 歧义（owner 拍板 2026-08-04：定为契约，签收）**：大小写不敏感匹配，多种大小写并存判 `capture_ambiguous`。**调查结论**：两端**生产传输层均归一化** header——server `transport/direct.ts` 用 WHATWG `Headers.forEach`（名全小写 + 同名合并）、client `transport/direct.dart` 用 `HttpHeaders.forEach`（名小写 + `values.join(', ')`）。**owner 定性 = (a)**：**声明「header map 到达 masker 前已归一（键小写、同名合并、Set-Cookie 另路）」为契约**；`capture_ambiguous` 分支记为 **belt-and-suspenders 纵深冗余**（防非归一化上游 / firewall 手搓 map），保留不删。golden `header_ambiguous_case_fail_closed` 用手搓双大小写 map 证明护栏仍有效。**C1 接线约束**：firewall 组装/透传 header map 时不得破坏该归一契约（列入 C1 审查项）。
- [x] **B5 日志 / 诊断纪律（引擎层 owner 签收 2026-08-05）**：`capture_*` / `project_overlap` / `capture_duplicate_key` / `capture_too_deep` / `capture_budget_exceeded` 全 fail-closed；消息**不含原值/命中片段/敏感 URL**（ADR §2.4）。C1 的 DEV/DEPLOY 发射接线仍独立待审。
  - **B5 契约（owner 拍板 2026-08-04，决议已落，发射挂 C1）**：对宿主诊断的**稳定契约 = §3.3 结构化字段**（`code`/`ruleId`/`source`/`path`\|`headerName`/重复键 `key`），**非 message 文案**；DEPLOY 丢 message、留稳定 `code`。发射由 C1 firewall 上层 catch 在 **ADR-024 DEV profile** 决定（`ruleId`/`path` 上下文只在规则层可得）。ADR-024 前若临时挂 `kDebugMode` 须标注为临时通道。C1 接线后扫上层 catch / 遥测。
  - **finding 3（引擎携带 `key`）**：重复 sibling 键名只在引擎层可得，故 `MaskerError.detail.key` / `MaskerException.key` 在 `capture_duplicate_key` 时携带（golden `errorKey` 双端校验）；只含键名。至此 §3.3 白名单里引擎层可得字段（`code`+`key`）已可兑现，规则层字段（`ruleId`/`path`）由 C1 补。
- [x] **B6 golden 覆盖补强（双端 52 例）**：非 BMP 前置剪接、代理对、末尾反斜杠、转义引号（B3）；深度 512 成功 + 513 拒 + 超深畸形优先级 + 串内括号不计深（B2）；超安全整数下标；escaped-equivalent 重复键 + `key`；`project_overlap`；共享前缀 + 嵌套数组；跨分支错误优先级；共享 `generatedLimits` 生成式向量覆盖 **Header UTF-8 4 KiB、Body 8 MiB、Capture value 64 KiB** 三类超限，以及 **80,000 键 × 64 rules（契约上限）单索引复用成功**。向量改动随 B1 方案 B 一并待人工复核。

### B1 finding 1（CPU 放大 · 方案 B 已实现、待 owner 复签）

方案 A 的 `navigate` 为检测重复键会扫**完整对象层**、随后递归目标子树；`applyResponseMasker` 每规则各跑一次 Capture、`projectResponse` 又对每条 json 路径重新 `locateJsonSpan` → 总代价 **O(body × path depth × rule count)**。深度限只防栈溢出、**不限累计扫描量**。

**方案 B 实现**：
- 先把所有 JSON rule 的 token 路径合并为前缀树；平台 parser 判合法后，`scanIndexedValue` 只线性经过 body 一次，仅为规则可达节点保留 span / kind / children，并在导航对象层记录首个重复键。
- Capture 与 Project 都经 `lookupJsonSpan` 查同一索引；查询仍按规则顺序执行，保持缺失、类型、重复键与 overlap 的错误优先级。
- 索引增量内存最坏为 O(规则可达节点 + 所有活跃导航层 sibling keys)，可达 O(body)；无关子树由 `scanValue` 一次跳过。平台 parser 为整体合法性校验仍短暂构造完整 DOM，峰值评估必须包含它；owner 复签须评估 8 MiB 移动端峰值。
- spans 排序后一次顺序拼接投影响应，避免不可变字符串逐规则整包复制重新引入 O(body × rules)。
- `MAX_SCAN_BUDGET = 16 MiB` 继续计量 `assertJson` 的一次线性成本和索引的一次线性扫描；在 8 MiB UTF-8 body 上不再随 rules 增长，主要作为未来计费漂移的不变量护栏。
- **测试**：共享生成式向量 `transaction_single_index_reused` 描述 80k 键对象 × 64 rules（契约上限），两端均须成功、64 处 sentinel 正确且无关尾值不漂移；另三例继续锁 header/body/capture-value 超限。

**签收状态**：2026-08-05 的 owner 签收覆盖方案 A 安全基线；方案 B 重写了承重扫描器，当前仅完成实现与双端测试，必须由 owner 重新逐行复签。差分模糊测试（平台解析 / scanner span / 剪接后 JSON 三方一致 + 孤立代理）仍是长期增强。

---

## C. 后续阶段收尾（step 4→9，均须人工主导）

- [ ] **C0 前置：修 ADR-023 源响应投影缺口**（ADR §3）：「中间值从不进 adapter」叙述与「源响应仍交付」之间有缺口，step 5 前必须人工修订并测试。
  - **进度（2026-08-03，🔒 待人工确认）**：**文档修订已落**——ADR-023 §4 加「精确边界」（从不进 adapter 严格成立于 broker 内部句柄 + 下游回显剥离；credential-sensitive `bind` 源响应由 ADR-026 firewall 投影兜底）、§3 落地步骤加 ⑦「源响应投影后交付」；ADR-026 §3 记 C0 处置。**「测试」随 C1 落地**：delivery firewall 交付事务须含「源响应投影后再交付」raw→delivered 用例（firewall 骨架已标该 seam）。
- [ ] **C1 统一 delivery firewall（step 4）**：证明 declarative / imperative / actuator 三入口不可绕过；生产侧无直接构造 adapter-visible 响应的旁路。**并入 A3**：传输层→Broker 边界对非法 / 非 UTF-8 body fail-closed。**并入 A6**：提交前 assert `captured.length ≤ 1`。
  - **接线进度（2026-08-05，🔒 待人工审）**：**imperative 入口已接线**——`fetch-proxy.ts` `proxyFetch` 每次 `ctx.fetch` 交回 adapter 的响应改为**强制经 `deliverThroughFirewall`**（原末尾裸 `processResponse` 已移除）；无 Masker 策略 → 空规则透明交付，与旧行为逐字节等价（现有 imperative/all smoke 26/26 全绿证行为保持）、**结构上无旁路**。sandbox `ImperativeAdapterDeps.masker`（三件套 `rules`/`sink`/`ctx`，缺省无策略）为注入点；`deps.masker` → `proxyFetch` → firewall 端到端 smoke 证「命中值投影 sentinel 后交付、原值只落核心 store」（`sandbox.imperative.smoke.ts` test 7）。**owner 决议（2026-08-05）已处置**：**A3 真实判定已接入**——`transport/direct.ts` 按 charset + `fatal` UTF-8 解码产出 `TransportResponse.decodeOk`，proxyFetch 以 `resp.decodeOk ?? true` 传入 firewall（`false`→`body_not_plaintext` fail-closed；transport smoke 8/8 + imperative A3 e2e test 8 绿）；**注入凭证回显 = 不做反射检测**（owner 拍板：短字符反射误报，交 Masker `redact` 承担），故 imperative 维持不 strip、firewall ⑦ `injectedValues` blanket 剥离**待退役**（与 ADR-023 §2.5 冲突，改写 + 代码移除待 owner 签收）；**三入口统一收口已确认**（ADR-030 已接受）。**Policy 匹配契约已就近修订 ADR-026 §2.10**（`match{urlPattern/status/contentType}`→rules 并集，Broker firewall ② 解析、纯引擎只吃选定 rules）。**仍待人工主导**：① **declarative + actuator** 两入口接线（actuator 入口代码待随 ADR-030 落）；② Policy 匹配的 **schema/validator + 解析实现 + store 装配**（§2.10 契约已定，实现未落）；③ 真实 Store 原子性（C2）；④ A3 的 Dart transport 镜像 + charset golden；⑤ firewall ⑦ 退役 + ADR-023 §2.5 改写。
  - **进度（2026-08-03，🔒 待人工审）**：骨架已起草 `server/src/runtime/broker/delivery-firewall.ts`——单 choke point `deliverThroughFirewall`，按 ADR-026 §2.4 次序编织已落地零件：① **A3** 明文边界断言（`transportDecodeOk=false → body_not_plaintext` fail-closed）→ ②→⑤ `applyResponseMasker`（Capture/Validate/Project，含 **C0 源响应投影**）→ ⑥ `commitMaskerCaptured`（**A6** 在此，未声明 ref fail-closed）→ ⑦ `stripEchoes` 下游回显剥离 → ⑧ `processResponse` header allowlist 脱敏。**交付事务 fail-closed**：任一步抛错绝不交付原响应、绝不半提交。smoke `delivery-firewall.smoke.ts` 7 组绿（含 **C0 raw→delivered 源投影 + 落库闭环**、编码二进制文本投影、header 源删除、A3 fail-closed、事务不半提交、无策略仍经 choke point、回显剥离）；dataflow shared golden 另含 bytes→base64/base64url text→后续 compute/inject 两条双端 pipeline。**seam（待接线，人工主导）**：② Policy 匹配（`masker.json` match→rules，现由调用方传入）、① A3 真实 UTF-8 判定（传输层职责）、⑥ Credential Store 原子性 / generation swap（真实 SecureStore）；**替换三入口现有直接交付**（如 `fetch-proxy` 末尾 `processResponse`）+ 无旁路证明是接线主步。
- [ ] **C2 Commit 接线（step 5）**：Credential Store 原子提交（§2.4 单持久 ref + generation swap + 崩溃语义）；ADR-023 opaque handle staging；handle 源投影（§3：同次 raw 提取执行 bind 一次，产出 staged handle + 投影响应，不重复计量）。
  - **进度（🔒 待人工审，未接入 live 路径）**：落库中段已起草 `server/src/runtime/broker/masker-commit.ts`（`planMaskerCommit` 纯编排 + `commitMaskerCaptured` 薄桥接到 `CredentialStore.put`，与 `harvest.ts` 同构）。含 **A6** 运行期 assert（`captured.length ≤ 1` → `commit_multiple_credentials` fail-closed）、未声明 ref → `commit_ref_undeclared` fail-closed（已收割敏感值绝不静默丢，异于 harvest 的防御性跳过）；type/scope 取自 manifest decl（ADR-012 §2.4）。smoke `masker-commit.smoke.ts` 5 组绿（含 Capture→Commit→`get(ref)` 闭环，via=header 供命名头注入）。**仍缺**：原子性 / generation swap / 崩溃语义（走真实 store 落地，非本原型桥接）；接入 live 交付路径 = C1 firewall 无旁路证明 + C0 源投影缺口前置（下）。Dart 侧镜像随客户端核心（同 harvest 目前 TS-only 原型）。
- [ ] **C3 host/version gate**：落地后移除 validator `RM0_host_gate_unavailable` 阻断；同步改 **ADR-018** bundle 内容说明（`masker.json` 为受版本门约束的可选签名运行时文件）；旧 host 遇新 bundle 拒载。
- [ ] **C4 §7.4 尚缺项**：charset / 压缩 / 非法编码语义（呼应 A3，多数属传输层）由 golden 钉死。
- [ ] **C5 §10 发布/吊销门**：observation→rule→destination→replay 闭合；raw canary 不出现在 delivered fixture；policy diff / 删除 waiver；旧漏洞版本 revocation / `minVersion`；review fixtures 不进 bundle；签名台账加 `maskerDigest`。
- [ ] **C6 §2.6 adapter-side 提取 scanner**：token/session/cookie、认证 header、跨请求值传递、高危正则作**人工审查触发器**（非自动裁定）。
- [ ] **C7 §12 人工签收**：schema+失败语义、firewall 无旁路、Store/handle 生命周期、golden+raw-to-adapter replay、无真实凭证/学生数据、发布/吊销/回退演练。

---

## D. elecon-adapters 侧改动

> adapters 在 `ncc-devlab`、合并后自动镜像；客户端按需拉取（`adapters.pin` + `fetch-adapters.sh`）；per-capability 门 `check-adapters.mjs` 仍 DRAFT。

- [ ] **D1 bundle 内新增 `masker.json`**（schema v1，adapter 根，进 digest + 官方签名）；确保按需拉取/镜像链路一并带上。
- [ ] **D2 manifest 声明 credential ref**：`credential` 目标引用的 ref 须在 manifest 已声明（validator RM8），形态依赖 **ADR-029**。**ADR-029 已接受（2026-07-31）**，§2.1 命名 header 的契约、validator、Broker 纯函数/拼装、客户端两个生产 manifest parser、双端 runtime CH1–CH3 与共享 golden 已落地；verified manifest→Broker view 及 Dart policy→resolver→transport 集成测试已补（🔒 待人工逐行安全签收）。**进度**：Masker Commit → Credential Store 写入该 ref 的落库中段已起草（见 C2 进度：`masker-commit.ts`，smoke 含 `aircon-session`→`x-access-token` 闭环，🔒 待人工审、未接 live）；`aircon-session` 等 ref 正式声明随首例（D7）落。**仍待**：接入 live 交付路径（C1/C0）。
- [ ] **D3 审查材料 `review/`**（`fixtures/raw`、`fixtures/delivered`、`security-observations.json`）放仓库但**不进发布 bundle**；CI 校验不被打包。
- [ ] **D4 迁移盘点（§9.1）**：逐个扫 adapter/probe 对 header/body/URL 的正则/JSONPath/切片提取 `token/session/code/openid/client_id`、cookie value 来源（`setEphemeralCookie`）、跨请求值流；逐项人工分类，不按变量名批改。
- [ ] **D5 迁移改写**：命中值改走 Broker credential 注入或 ADR-023 handle；删除 adapter 自行读取/保存/正则/日志/手工拼请求。
- [ ] **D6 `check-adapters.mjs` 扩门**：把 masker 校验与 observation→rule→replay 闭合纳入 adapters 侧 CI。
- [ ] **D7 首例：聚好联空调**（命名 header 注入小闭环），**必须虚构 token/设备 ID**。ADR-029/030 均已接受；首例仍受 D2 命名 Header 生产接线、C1/C2 live firewall/store 及 actuator 执行闸门阻塞。
- [ ] **D8 贡献规范补 A1 推荐**：明文写入 adapter 作者指南——「能 `redact` 就不 `handle`」，减少核心接触面。
