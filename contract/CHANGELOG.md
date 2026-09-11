# `contract/` 变更流水

> **这是什么**：`contract/`（schema、`capability/registry.json`、`manifest.schema.json`）每一次新增或变更的 dated 记录。
> **权威关系**：**决策**的权威在 ADR 正文（治理规则见 [`adr_001_contract.md`](../docs/adr/adr_001_contract.md) §8）；**落地与安全签收**的权威在 [`docs/adr/README.md`](../docs/adr/README.md) 索引表。本文件只记「契约事实上被改成了什么、依据哪条 ADR」。
> **红线 #6 如何不被弱化**：每条记录**必须引用一个 ADR 编号**——记录的存在即证明该变更「先有 ADR」。无 ADR 引用的条目视为违规。
> **与 `docs/archive/` 的区别**：`docs/archive/` 存**已被取代、不再维护的历史快照**（只读）；本文件是**活的时序流水**，是当前契约版本号的解释来源（例如「为什么 registry 里 `notice.list` 是 1.1」）。
>
> 排序：**新的在上**。本文件的前三条于 2026-09-08 自 ADR-001 §8.1 原样迁入，内容未改，仅补记人工复核结论。

---

- **2026-09-11 · `catalog.schema.json`：entry `url` 弃用（从 required 移除），catalog 只描述文件、不描述端点（ADR-018 §2.5.1）**
  - **改动**：`entries[].url` 从 `required` 移除并标记弃用（description 注明）；`additionalProperties:false` 不变，字段暂留为可选。
    顶层与 `entries` / `digest` 的 description 改写为「以 digest 内容寻址，路径恒为 `bundles/<digest>.json.gz`、相对客户端自持 base」。
  - **为何**：`url` 在签名字节里，把端点域名绑进了 catalog——换域名/上镜像/指向本地端点都要重签，而字节来源本不参与信任裁定
    （digest 重算 + Ed25519 验签才是锚）。ADR-018 §2.5.1 决定 catalog 不再描述端点，base URL 由客户端自持。
  - **为何暂留可选而非直接删除**：线上/bootstrap 的 catalog（sequence 8）已签且含 `url`；删字段会令其不合 schema，只为此重签不值一次
    YubiKey 仪式。留可选 = 旧 catalog 仍合法、新 catalog 不再写入。**下一次仪式（已预定 masker `/3` 断代，catalog ≥ 9）后删除**。
  - **同批落地**：`tools/src/catalog/validate.ts`（`url?` + K3 弃用 warn）、`tools/src/release/package.ts`（不写 url、移除 `--base-url`）、
    catalog golden 重生成（entries 无 url）、`client/lib/core/loader/catalog.dart`（解析时忽略 url）、`loader.dart` / `distribution_http.dart`
    （`fetchBundle(digest)`，按 digest 拼路径 + 形态门）、`adapter_service.dart`（自持 base + DEV `ELECON_DISTRIBUTION_BASE_URL` 覆盖）。
    tools smoke 19/19、client `flutter test` DEPLOY 859 / DEV 868 通过。
  - **依据**：ADR-018 §2.5.1（2026-09-11 修订）。🔒 触红线 #4 加载路径与 #6 契约，实现须人工复核签收。

- **2026-09-09 · `elecon.gpa.summary` 1.0 → 1.1：绩点尺度 + 全字段 description（ADR-001 §3.5 优先级规则）**
  - **改动**：
    1. `elecon.gpa.summary` 新增可选 `gradePointScale`（枚举同 `elecon.grades.list`）——**官方 GPA 此前没有量纲**：只有一个 `gpa: number`，UI 无从判断 3.71 是 4.0 制还是 5.0 制的。
    2. 该 schema 原本除 `updatedAt` 外**全部字段无 description**，本次补齐 8 处（顺带削减 description gate 的 367 处欠账）。
    3. `elecon.grades.list` 的 `gradePointScale` description 改写（内容语义不变，见下）。
    4. registry 级联 `gpa.summary` 的 `emits.schemaVersion` → `1.1`；codegen Dart/TS 重跑；schema golden 增 `gradePointScale` 正例与 enum 负例。
  - **为何**：ADR-001 §3.5 此前只写了一句「`gpa.summary` 存在时优先」，没有说清**为什么有两个 GPA**、以及两者同时可见时怎么办。本次把它展开为显式规则：**学校官方 GPA（`gpa.summary`，adapter 只读不算）** 与 **交互式聚合 GPA（本体按当前筛选算）** 是两个数、两个所有者、互不替代；官方数存在即权威，本体不得覆盖；两者同现必须用**不同标签**。既然官方数要独立展示，它就必须自带量纲——故补 `gradePointScale`。
  - **为何是 MINOR**：仅新增一个可选字段 + 补 description，不删字段、不改既有类型、不收紧约束；旧 1.0 数据在 1.1 下仍合法。
  - **description 改写（`grades.list.gradePointScale`，非结构变更）**：补三条此前隐含未言明的约束——① 该字段**只界定量纲、不保证跨校可比**（同称 4.0 制的两校换算表可能完全不同），故不得据此做跨校排名；② `other`（知道制式但不在枚举内）与 `unknown`（无法判断）**信号不同**，前者提示扩枚举、后者提示 adapter 待改进；③ 数据横跨学校改制时**不得任选其一**，应声明 `other` 让本体降级。
  - **消费方新增义务（本体侧）**：`gpa.summary` 可用即作为权威展示；本体自算值只在「无官方数」或「用户施加了筛选」时出现，且**必须换标签**（绝不允许两个不同的数都叫 GPA）。两路都对 `gradePointScale` fail-closed。官方数的尺度取自 `gpa.summary` 自身，**不得借用** `grades.list` 的——两者可能覆盖不同范围。
  - **依据**：ADR-001 §3.5（2026-09-09 修订，新增优先级规则表）。
  - **本仓内已同批完成**：schema、registry、codegen、schema golden 正负例、客户端（`GpaSummary` 解码 / `CampusSnapshot.gpaSummary` / `GradesCard` 官方优先 + 本机聚合改标签「均绩 … 本机计算」/ `GradesSection` 取 `gpa.summary` 作可选增强，失败不影响成绩单）、3 个新增 widget 测试锁死优先级与 fail-closed。
  - **未同批（外部仓）**：`elecon-adapters` 目前**无任何 adapter 声明 `gpa.summary`**，故本次无阻塞性外部联动。将来实现该能力的 adapter 须直接按 `1.1` 声明并给出 `gradePointScale`。

- **2026-09-08 · `elecon.grades.list` 1.0 → 1.1：绩点尺度与派生来源（ADR-001 §3.5 修订）**
  - **改动**：
    1. 列表级新增可选 `gradePointScale`（枚举 `4.0` / `4.3` / `4.5` / `5.0` / `other` / `unknown`）——声明本次成绩里 `gradePoint` 所用的**校本计分尺度**。
    2. item 级新增可选 `gradePointSource`（枚举 `source` / `adapter-derived` / `unknown`）——区分该绩点是**学校来源直接给出**还是**adapter 按校本换算规则派生**。
    3. `gradePoint` 字段 description 相应改写（不再断言「学校来源直接提供」）。
    4. registry 级联 `grades.list` 的 `emits.schemaVersion` → `1.1`；`adapters/_template/{declarative,imperative}` manifest 同步；codegen Dart/TS 重跑。
  - **为何**：ADR-001 §3.5 原文在同一段里先给判据「校本特有的派生 → adapter；跨校统一的派生 → 本体」，又把 `gradePoint` 判给 UI 计算——**自相矛盾**。分数→绩点的换算表是校本的（各校甚至各院系不同，尺度有 4.0/4.3/4.5/5.0），按判据属 adapter。矛盾的根源是一个词承担了两件事：**课程级 `gradePoint`（校本换算）归 adapter**，**GPA 聚合（加权平均/排序/跨学期对比）归本体**。本次改动把这一拆分落到契约上：adapter 派生不再是「擅自推算」的禁止项，而是**可声明、可审计**的交付物。
  - **为何是 MINOR**：仅新增两个可选字段 + 改写一处 description，不删字段、不改既有类型、不收紧约束；旧 1.0 数据在 1.1 下仍合法。
  - **消费方新增义务（本体侧）**：`gpa.summary` 存在时优先采用学校侧汇总；否则本体自行计算，且**当 `gradePointScale` 缺失、为 `unknown`/`other`，或跨数据源尺度不一致时不得展示 GPA**（fail-closed，而非展示一个尺度不明的数）。
  - **依据**：ADR-001（2026-09-08 修订，§3.5 判据改写 + §8 治理规则）。
  - **联动升级文档**（§8 要求）：[`docs/reference/gradepoint_ownership_landing.md`](../docs/reference/gradepoint_ownership_landing.md) —— 含业务动机、预期结果、逐项外层联动清单与验证结果。
  - **本仓内已同批完成**：schema、registry、codegen、`adapters/_template` 两套（manifest + index.js + fixtures）、客户端 GPA fail-closed 与解码、schema golden 正负例、客户端回归。
  - **未同批（外部仓，见联动文档 §4.1）**：`elecon-adapters` 的 `school-xidian` / `school-thu` manifest 仍写 `elecon.grades.list@1.0`，须同步 `1.1`，否则 `C2_emits_mismatch` 拒签发、运行时查不到 validator 而 fail-closed。

- **2026-07-22 · `classroom.available` 1.0 → 1.1 + 新增 `classroom.buildings`（ADR-019）**
  - **改动**：
    1. **`elecon.params.classroom.available` / `elecon.classroom.available` → 1.1**：双时间轴（`date`/`week`/`term`/`weekday` + 节次 `sectionStart`/`sectionEnd` + 墙钟 `start`/`end`）；楼/室过滤 `building`/`buildingId`/`room`/`roomId`；`onlyAvailable`；emits 增 `sections[]`（`maxItems:24`）、`status` 枚举追加 `partial`、`timeZone`（IANA，adapter 声明）、`floor` 等。`items[].building`+`room` 仍 required 且 `minLength:1`，未知填 `"-"`。
    2. **新增伴生 capability `classroom.buildings@1.0`**（discovery）：params 可选 `campus`/`term`；emits `items[]` required `building`。
    3. registry 级联 `schemaVersion`；codegen Dart/TS 同步。
  - **为何是 MINOR**：仅新增可选字段 + 枚举扩展（放宽消费方须按 ADR-001 §3.4 对未知枚举兜底 `unknown`）+ 新 capability；不删字段、不改既有类型；旧 1.0 数据在 1.1 下仍合法。
  - **依据**：[ADR-019](../docs/adr/adr_019_classroom_available.md)（2026-07-22 Accepted）。
- **2026-06-16 · `elecon.notice.list` 1.0 → 1.1**（依据 ADR-001；**人工复核完成 2026-08-22 · owner NanCunChild**）
  - **改动**：`publishedAt` 由 `required` 移出，成为可选字段（schema 内容不变，仅放宽必填约束）。级联 `capability/registry.json` 与 emit 它的 manifest（school-xidian / school-xjt）的 `emits.schemaVersion` 同步至 `1.1`。
  - **为何是 MINOR 而非 MAJOR**：ADR-001 §8 把"收紧约束"列为破坏性，本改动是其**反向（放宽）**。ADR-001 §3.4「缺失语义」本就要求消费方普遍处理"字段缺失 = 该校不提供"，故把 `publishedAt` 改为可选**不超出消费方既有义务**，旧数据（含 `publishedAt`）在 1.1 下仍合法 → 向后兼容，记 MINOR。
  - **本次遇到的情况**：首个 imperative adapter（school-xjt 教务通知）逆向中，源站通知日期偶为不可解析格式；旧 `normalizeDate` 不可解析时回退空串 `""`，而 `""` 不是合法 `date-time`，会被 ajv 拒。改为不可解析时**省略 `publishedAt`**（语义 = 该条目未提供可信日期），与 ADR-001 §3.4 一致。
  - **是否可能引入未知问题（风险）**：
    1. **消费方（UI/SDUI）**：若某处实现假设 `publishedAt` 必存（如直接排序/格式化），缺失时可能报错或排序错位。缓解：UI 须遵 ADR-001 §3.4 处理缺失；按时间排序时对无日期项定义稳定兜底位次。
    2. **新旧版本并存**：1.0 与 1.1 同时在网（不同 adapter/缓存）时，宿主以 envelope `schemaVersion` 解读；1.1 消费方需容忍缺省，1.0 数据天然满足。
    3. **一致性外溢**：其他域 schema 可能存在同类"过紧 required"（如把可能缺失的字段标必填），本次只动 notice.list，未做全面审计——留作后续核对，不在本改动范围。
    4. **校验盲区**：`tools/` 校验器目前不对 params schema 做加载校验，emits 版本一致性（C2）已覆盖本次级联；fixtures 仍含 `publishedAt`，1.1 下照常通过。

- **2026-06-16 · 新增 `elecon.card.transactions` emits schema + 5 个 `params.*` 草案 schema（补 registry 悬空引用）**（依据 ADR-001；**人工复核完成 2026-08-22 · owner NanCunChild**）
  - **改动**：补齐 `capability/registry.json` 早已声明却**无定义文件**的 schema——
    1. **`elecon.card.transactions@1.0`（emits，稳定面）**：money 模型镜像 `card.balance`（`amountMinor` + `currency`），增 `direction`（debit/credit）区分收支；`amountMinor` 加 `minimum:0`（交易额恒非负，收支由 `direction` 表达，区别于 `card.balance` 可为负的余额，已在 schema `$comment` 注明）。
    2. **5 个 `params.*` 草案 schema**：`grades.list` / `schedule.week` / `card.transactions` / `notice.list` / `generic.section`，消除 registry 悬空 `params` 引用。均带 `$comment: 草案`。
  - **范围**：仅新增 `contract/schema/` 文件；未改 `registry.json`、未新增/改 capability id、未改任何既有 schema 语义。registry 的 `$schema` 错误指向已拆至 #48 单独修复。
  - **草案（draft）状态约定**：上述 5 个 `params.*` 在经本 ADR **正式确认（"转正"）前不属稳定契约面**——adapter / UI 不得将其当稳定依赖。**草案期内其形状可自由调整（增删字段、改约束）而不触发 ADR-001 §8 的 MAJOR/MINOR 版本治理**；版本治理仅自该 schema 转正后生效。此约定为契约早期高频迭代（按真实接口反复校准）留出空间，同时不削弱红线 #6——草案明标、不被依赖、转正须在本文件补记。
  - **待人工确认的设计点（草案期跟进，非阻塞本次补齐）**：
    1. `params.schedule.week.week` 设为 `required` 是否需核心侧配套「当前教学周」能力（否则消费方无从得知传第几周）；
     2. `params.card.transactions` 的 `from`/`to` 与 `page`/`size`：已知学校（XIDIAN）流水接口仅支持分页（`pageNo`/`pageSize`）、不支持日期范围，故 `from`/`to` 设可选以适配跨校差异，由 adapter 归一化映射。

