# ADR-025：item 级可点性约定——详情下钻标识与外链字段

- **状态**：已接受 2026-07-25，经人工复核后接受。数据面（`contract/schema/` item 链接字段）属红线 #6 流程内的**向后兼容增量**（早期阶段豁免见 [`docs/rules/schema_style.md`](../rules/schema_style.md)）；§2.7「外跳凭证隔离」触**红线 #1**（凭证永不离开核心）——该 UI 承重约束的**实现**须另行人工安全复核，AI 不得独自闭环（AGENTS §1）。半可信 adapter 不得驱动渲染的边界不变（ADR-004 §2.1）。
- **日期**：2026-07-25（草案）
- **依赖**：[`adr_001_contract.md`](./adr_001_contract.md)（§3.4 缺失语义 / §3.6 generic `role` 枚举含 `link` / §7 契约治理）、[`adr_004_ui_sdui.md`](./adr_004_ui_sdui.md)（§2.1 无 Widget 描述协议、§2.2 typed 详情视图、§2.3 `role:link → 可点击 + 外跳`）、[`adr_002_trust_model.md`](./adr_002_trust_model.md)（半可信 adapter 不得驱动渲染）
- **适用范围**：typed 域 item「可点」时数据面如何承载——① App 内下钻详情所需的稳定标识；② 外跳 webview/网页所需的链接字段。**不含**：具体 Flutter 组件、点击后的导航实现（属客户端 UI）、generic 兜底域（其 `role:link` 已由 ADR-001 §3.6 / ADR-004 §2.3 覆盖，本文不改）。

---

## 1. 背景（Context）

产品希望通知条目、成绩单课等 **item 级实体**「可点」——点击后进入详情页，或跳转到 webview/学校网页。直觉做法是「给字段加超链接」，但这与 ADR-004 §2.1 的承重决策直接冲突：**本项目否决了 Widget 描述式 SDUI，schema/adapter 不得驱动渲染。** 因此不能在字段上引入 `clickable` / `href` / `onTap` 一类**渲染指令**——那等于让半可信 adapter 控制 UI（触 ADR-002 安全边界）。

正确的模型 ADR-004 已定：**schema 只承载「语义 + 数据」，客户端决定「是否可点、点了去哪」。** 但 ADR-004 只在 §2.2/§2.3 一笔带过，未把 typed 域 item 的「可点性数据契约」钉死。审计 `contract/schema/` 发现两点现状：

- **App 内下钻所需的标识已普遍存在**：`notice.list.items[].id`、`grades.list.items[].courseId`、`exam.list.items[].courseId`、`dorm.service.items[].id`、`invoice.list.items[].invoiceNo` 等——每个 item 都带领域内天然的稳定标识。
- **外链字段以「语义命名」零散存在**：`notice` 的 `url` / `attachments[].url`、`invoice.list` 的 `downloadUrl`、`app.announcement` 的 `privacyUrl`。命名各异但都 `format:uri`，符合仓库「命名即语义」取向。

缺的不是字段，而是一条**成文约定**：防止日后有人把「可点」误实现为渲染指令，并统一「何时该加外链字段、该怎么命名」。

---

## 2. 决策（Decision）

### 2.1 「可点」是客户端渲染决策，不是 schema 字段

重申 ADR-004 §2.1 并将其钉为 item 级硬约束：

- schema **不得**出现 `clickable` / `href` / `link:true` / `onTap` / `action` 等**渲染或行为指令**。是否可点、点击手势、跳转方式一律由客户端硬编码卡片（typed）或模板（generic）决定。
- schema **只提供数据**：一个稳定标识（用于 App 内下钻）和/或一个 `format:uri` 的链接值（用于外跳）。客户端据 `emits.schema` 选卡片，卡片自行决定把哪个字段渲染成点击目标。

### 2.2 App 内下钻：复用 item 的稳定标识，不新增「链接」字段

typed 域 item 的详情下钻（通知正文、成绩单课详情等，ADR-004 §2.2 已列）**不需要任何新字段**：

- 客户端以 item 已有的领域标识为键做 App 内导航（`notice.id` → 拉 `notice.detail`；`grades.courseId` → 单课详情视图）。
- 该标识**已是 item 契约的一部分**，本文不改其 required/命名。缺标识的 item schema 若确需下钻，另按 §2.4 评估补一个**领域命名**的标识（非笼统 `id`）。

### 2.3 外跳 webview/网页：`format:uri` 链接字段，按用途命名

item 确有「每条一个源页/可下载资源」时，用一个 `format:uri` 字符串字段承载 URL，**字段名表达用途**（延续现状：`url`=条目自身页面、`downloadUrl`=可下载件、`privacyUrl`=隐私政策、`attachments[].url`=附件）：

- 字段**始终可选**（`format:uri`，不进 `required`）；缺失遵循 ADR-001 §3.4「缺失即省略」，不得填空串（否则违反 `uri` 校验，参照 ADR-001 §8.1 `publishedAt` 教训）。
- **只在源站确有该资源时才加**。本体**算出来/聚合**的数据（成绩、绩点、卡务流水）源站无「单条网页」，**禁止**臆造 `url`——否则点击指向无效页面，误导用户。
- 一个 item 可有多个用途明确的 URL 字段（如 `invoice` 的 `downloadUrl`），不强行合并成单一 `url`。

### 2.4 何时给 item 补链接字段（判据）

| 诉求 | 数据面做法 | 是否需要新字段 |
|---|---|---|
| App 内进详情页 | 复用 item 现有领域标识 | 否（标识已在） |
| 跳 webview / 外部网页 / 下载 | 加 `format:uri` 字段，按用途命名 | 仅当源站确有该资源 |
| generic 兜底字段可点 | `role:"link"` + value 为 URL 字符串 | 否（ADR-001 §3.6 已有） |
| 本体计算/聚合数据 | —— | 否（无源页，禁止臆造） |

### 2.5 与 generic 域的关系

generic 兜底域走 `role:"link"`（ADR-001 §3.6 / ADR-004 §2.3），**本文不触碰**。两条路径并存且不重叠：typed 用命名字段（编译期已知语义），generic 用 `role` 提示（运行期语义）。

### 2.6 「是否可点」是数据驱动的，且分两种 affordance

「可点」由**数据存在性**闸门，不由 schema 指令闸门（延续 §2.1）。客户端须**区分两种 affordance，勿混为一谈**：

- **外跳 affordance（去 webview/网页/下载）——由外链字段是否给出闸门**：adapter 产出了 `format:uri` 字段 → 客户端渲染「在网页打开/下载」的点击目标；**字段缺失 → 该处不可点，退化为纯文本**（不显死链、不占位）。这正是「adapter 决定有什么数据、客户端决定怎么渲染」在可点性上的落点。
- **App 内下钻 affordance（进详情视图）——由 item 领域标识 + 客户端是否实现该详情视图闸门，与外链字段无关**：`notice`/`grades` 即便 adapter 不给外链，行内下钻（拉 `notice.detail` / 进单课详情）照常可点。**不得**因「无外链」就关掉下钻。

> 一个 item 可同时具备两种 affordance（如通知：点行进正文 = 下钻；「在网页打开」入口 = 外跳），也可只有其一。

### 2.7 外链不做前验证；反应式提示；且外跳须凭证隔离（🔒 安全）

- **禁止预取校验**：客户端**不得**在用户点击前对外链 URL 发起任何探测/预检请求。预取 = 替用户在其意图之前自动访问 adapter 选定地址；若该 URL 落在 `network.allow` + 凭证注入作用域内，预取可能**自动携带凭证**打出去（轻量 SSRF / 时序泄露）。新鲜度由 envelope TTL 承载（ADR-001 §3.3），外链一律按**尽力而为**对待。
- **反应式错误**：点击后才打开；打开失败/无内容时**事后**弹**通用**提示（如「该内容暂不可用」）。提示文案**不得回显** adapter 原始 URL 或原始报错串（防钓鱼文案注入）。
- **外跳凭证隔离（触红线 #1，须人工安全复核）**：adapter 提供的外链**绝不能在带凭证的会话上下文中打开**。若把该 URL 丢进共享了凭证 cookie jar 的 in-app webview，等于 adapter 选址、凭证随之外泄——直接违反红线 #1（凭证永不离开核心）。外跳**必须**走无凭证的干净上下文（系统浏览器，或**不注入任何凭证**的隔离 webview）。此约束是 UI 侧承重，落地实现须经人工安全签收。

---

## 3. 已知约束与风险（Consequences）

1. **新增外链字段是契约面**（红线 #6）。缓解：均为**可选、纯增量、向后兼容**——旧客户端忽略未知字段，旧 adapter 不产出即缺失。早期阶段按 schema_style 豁免向后兼容审查压力，但仍走 ADR（即本文）。
2. **adapter 仍可通过 URL 值误导**（指向钓鱼页）。这是数据内容风险，非渲染控制风险——与 ADR-004 §3.4「adapter 可用假数据误导，但不能伪造官方样式」同源。缓解：外链在客户端应以「离开应用/外部链接」样式明示，且受 adapter `network.allow` 之外的常规外跳确认约束（UI 实现细节，不入本契约）。
3. **命名分散**（`url`/`downloadUrl`/`privacyUrl`）而非单一 `url`。这是**有意选择**（命名即语义，优于笼统 `url` + 类型枚举）。代价：客户端需按字段名分别接线——可接受，字段少。
4. **不覆盖「item 内富文本里的内联链接」**（如通知正文 HTML 中的 `<a>`）。那属正文渲染/解析范畴（ADR-011 HTML parser），非本文的结构化字段面。
5. **外链可点性 = 数据存在性**（§2.6）：adapter 不给外链字段则该处不可点。代价：同一 schema 的两个 item 可能一个可外跳、一个不可——这是有意的（可点性反映数据真实存在性，非样式开关）。
6. **外链不预验证**（§2.7）：可能出现「可点但打开后是死链」。这是**刻意**接受的代价——换取不预取（避免凭证/时序泄露），以反应式通用提示兜底。
7. **外跳凭证隔离依赖 UI 侧正确实现**（§2.7，🔒红线 #1）：契约面只保证「adapter 给的是 URL 值」；「打开时不带凭证」是客户端承重，须人工安全复核，不能由 AI 独自闭环（AGENTS §1）。

---

## 4. 落地清单（草案接受后可拆小 PR）

现状审计与增量（typed 域 item schema）：

- `notice.list` / `notice.detail`：`url` + `attachments[].url` —— **已齐**，无改动。
- `invoice.list`：`downloadUrl` —— **已齐**（即其外链），无改动。
- `app.announcement`：现仅 `privacyUrl`（隐私政策），**缺公告自身页面链接** —— 本 ADR 增补可选 `items[].url`（`format:uri`）。**（本文随附此一处 schema 增量）**
- `dorm.service`：有 `id`（App 内下钻够用），源站无「每条工单网页」 —— 不补 url。
- `grades` / `exam` / `card.transactions`：本体计算/聚合，无源页 —— **禁止**补 url（§2.3）。

客户端侧（不入 contract/，属 ADR-004 落地，本文只记账）：

- ✅ **已落地（切片 1：App 内下钻，纯 UI 无红线）**：
  - 通知列表卡片：行 `onTap` → `NoticeDetailPage`（渲染快照内 title/meta/summary/`content`/附件名；`content` 补入 `schema_decode`）。
  - 成绩列表卡片：行 `onTap` → `CourseDetailPage`（渲染单课快照字段）。
  - 本切片**只渲染快照已有数据**，不新拉 `notice.detail`、不涉外链；附件/「在网页打开」暂不可点。widget 测试覆盖两条下钻导航；`flutter analyze` 净、`flutter test` 绿。
- ⏳ **待落地（切片 2：App 内下钻的网络增强）**：以 `notice.id` 拉 `notice.detail` capability 补全正文（数据层接线，非红线）。
- 🔒 **待落地（切片 3：外跳，触红线 #1，须人工安全复核）**：仅当 item 给出 `url` 时渲染「在网页打开」；外链渲染「外部链接」样式；**不预取校验**（§2.7），失败弹**通用**提示（不回显 URL/报错）；外跳走**无凭证上下文**（系统浏览器或不注入凭证的隔离 webview）。机制待选（`url_launcher` 系统浏览器 vs 隔离 webview）。
