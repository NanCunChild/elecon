# ADR-004：UI 层——数据驱动渲染与 SDUI 形态

- **状态**：草案（Proposed） 本文不触碰凭证/签名/传输承重路径，但涉及 adapter→UI 的契约交互面与安全边界（半可信 adapter 不得驱动渲染层）。改动 `contract/schema/` 需走红线 #6 流程。
- **日期**：2026-06-14（草案）
- **依赖**：[`adr_000_abstract.md`](./adr_000_abstract.md)（§2.2 分层、§4 "数据驱动 / SDUI"、§5.1 "放弃自建完整 DSL"）、[`adr_001_contract.md`](./adr_001_contract.md)（标准 schema §3 / generic 域 §3.6 / 角色枚举）、[`adr_002_trust_model.md`](./adr_002_trust_model.md)（adapter 信任分档——半可信 adapter 不得驱动渲染）
- **适用范围**：UI 层如何消费标准 schema 渲染卡片；typed 域 vs generic 域的渲染策略；adapter 与 UI 的职责边界；主题与角色映射。**不含**：具体 Flutter 组件实现、具体学校的 UI 适配。

---

## 1. 背景（Context）

ADR-000 §2.2 把 UI 层定义为"数据驱动 / Server-Driven UI，消费标准 schema 渲染卡片"，但**具体形态未定**——"SDUI"的含义从"完整的 Widget 描述协议"到"纯数据 + 客户端硬编码卡片"跨度极大。ADR-001 §3.6 落地了 generic 域 + 角色枚举，给出了数据面的解法，但"角色如何映射到主题样式"属 UI 层决策，ADR-001 显式声明"归 adr_004"。

需要回答的核心问题：

1. **adapter 的归一化产出到 UI 展示之间，有没有一层中间描述协议？** 如果有，它长什么样？如果没有，客户端怎么知道"这份数据用什么卡片渲染"？
2. **generic 域（长尾数据）的渲染策略**——没有预定义卡片组件时怎么展示？
3. **adapter 的渲染影响力边界**——在"adapter 绝不给样式"的红线下，adapter 能在多大程度上影响展示？

约束：
- 人力不足——不建大型 DSL/渲染引擎，Flutter 原生组件优先。
- adapter 不可信——半可信/侧载 adapter 不得伪造 UI（安全，ADR-002）。
- 一致性——聚合器的卖点是统一体验，不能 20 个学校 20 套视觉语言。

---

## 2. 决策（Decision，草案）

### 2.1 渲染策略：「typed schema 驱动客户端硬编码卡片」，无中间 Widget 描述协议

不采用"服务端下发 Widget tree JSON"式的完整 SDUI 协议。取而代之：

- **typed 域**（grades / schedule / notice / card / library）：客户端为每种 schema **硬编码**对应的卡片组件（Flutter Widget）。adapter 产出符合 schema 的数据，客户端据 `emits.schema` 选择对应组件渲染。**数据是标准 schema 本身，没有额外的渲染描述层**。
- **generic 域**（`elecon.generic.section`）：客户端提供**一组固定模板组件**（键值列表、简单表格、分节列表），据数据形状 + 角色枚举自动选择模板。adapter 只提供数据 + 角色提示。
- **"Server-Driven"的含义**：adapter 决定**有什么数据**（capability 声明 + 数据产出），客户端决定**怎么渲染**。"驱动"发生在数据层（schema 驱动 UI 组件选择），不在渲染层（无 Widget 描述）。

**为什么不做完整 SDUI 协议**：
- ADR-000 §5.1 已否决"自建完整 DSL"。
- Widget 描述协议需要维护"语言 + 运行时 + 文档"，与人力不足的现实冲突。
- 安全：Widget 描述赋予 adapter 渲染控制权，与"半可信 adapter 不得驱动渲染层"直接矛盾。
- 当前 typed 域已覆盖 5 个核心数据类别 + generic 兜底，**没有正当理由**为此建一套渲染协议。

### 2.2 typed 域的卡片组件约定

每个 typed schema 对应**一个主卡片组件 + 可选的详情视图**：

| schema | 主卡片 | 详情 |
|---|---|---|
| `elecon.grades.list` | 成绩列表（可排序/筛选） | 单课详情 |
| `elecon.schedule.week` | 周课表网格 | 无 |
| `elecon.notice.list` | 通知列表 | 通知正文（若有） |
| `elecon.card.balance` | 余额卡片 | 消费记录 |
| `elecon.library.loans` | 借阅列表 | 无 |

约定：
- 组件由客户端实现，**不由 adapter 或服务端下发**。
- 新增 typed schema = 新增客户端卡片组件 = 需要发版。这是有意的代价——typed 域本就走慢车道（ADR），新增频率低（预期一年几个）；换取的是智能（计算/提醒/聚合）+ 一致性 + 安全。
- **同一 schema 的不同展示形态**（如"成绩概览卡"vs"成绩完整列表"）由客户端内建多个 variant，不由 adapter 控制选择。

### 2.3 generic 域的渲染：固定模板 + 角色驱动样式

generic 域（`elecon.generic.section`）的 schema（ADR-001 §3.6）产出"带角色的键值组/表格/列表"。客户端渲染策略：

1. **模板选择**：据数据结构（单记录 vs 列表、字段数、是否含嵌套）自动选择模板。三种模板覆盖所有情况：
   - **键值列表**：单记录、少量字段（宿舍水电余额、学籍信息）
   - **简单表格**：多行同构记录（实验室空位、图书馆座位）
   - **分节列表**：多组异构字段（"本月水费 + 本月电费 + 总余额"各为一节）

2. **角色→样式映射**：字段的 `role` 枚举（ADR-001 §3.6：identifier / label / status / datetime / deadline / amount / quantity / link / unknown）映射到语义样式 token：
   - `status` → 状态着色（本体主题定义"正常/警告/异常"三色）
   - `deadline` → 截止时间样式 + 可选倒计时 badge
   - `amount` → 金额格式化 + 币种单位
   - `link` → 可点击样式 + 外跳
   - `identifier` → 加粗/突出
   - `unknown` → 默认文本样式，不做特殊处理

3. **adapter 影响力边界（不可逾越）**：adapter 通过 `role` 和数据结构**间接**影响渲染（"告诉本体这是什么语义"），但**不能**指定颜色/字号/控件/布局/排序。所有视觉决策由客户端主题系统统一。

### 2.4 主题系统（概要，具体实现不在本 ADR）

- 客户端维护**一套语义 token 系统**（颜色、字重、圆角、间距等），角色枚举映射到 token。
- 主题可切换（深色/浅色/高对比度），token 随主题变，组件不需感知。
- 主题设计是 UI 实现细节，**不进 contract/**——它只影响客户端，不影响 adapter 产出或服务端行为。

### 2.5 从 generic 升级为 typed 的流程

当某类 generic 数据满足以下任一条件，应启动 typed 域 ADR：

- 本体需要对该数据**施加智能**（计算 GPA、排序、提醒、跨校聚合）。
- 该数据类型在**三所以上学校**稳定使用，schema 趋于收敛。
- generic 模板无法良好展示（需要专用交互，如课表的网格视图）。

流程：开 schema ADR → 定义 typed schema → 注册 capability → 客户端实现卡片组件 → 发版。已有的 generic adapter 数据可**平滑迁移**：先升级 manifest 的 `emits.schema` 指向新 typed schema，adapter 归一化逻辑相应调整输出结构。

### 2.x 选型对比

| 取向 | 取 | 舍 |
|---|---|---|
| **typed 硬编码卡片 + generic 固定模板（建议）** | 最小复杂度；无渲染协议维护负担；一致性天然保证；安全（adapter 无渲染控制权） | 新增 typed 域需发版（可接受——频率低） |
| 完整 SDUI（Widget 描述 JSON） | adapter 可控渲染，无需发版加新卡片 | 需维护 DSL + 运行时；安全面巨大（adapter 驱动渲染）；一致性靠约定而非强制；人力不足致命 |
| 纯 generic（不分 typed/generic） | adapter 最灵活 | 本体失去智能——退化为浏览器，产品价值归零 |

---

## 3. 已知约束与风险（Consequences，草案）

1. **新增 typed 域需发版**。typed 卡片是客户端硬编码，不可热替换。缓解：typed 域新增频率低（预期一年数个）；generic 兜底确保新数据可先上线再慢慢升级。
2. **generic 模板表达力有限**。三种模板不能覆盖所有展示需求（如需要图表、日历视图）。缓解：这些场景正是升级为 typed 域的信号。
3. **角色枚举是新的契约面**。`role` 枚举列表变更 = 契约改动（红线 #6）。缓解：枚举有 `unknown` 兜底；新增角色是向后兼容的（旧客户端对未知 role 按 `unknown` 渲染）。
4. **adapter 仍可通过数据内容误导用户**（如假通知、假余额），但不能通过 UI 控制伪造"官方"样式。这是"adapter 不给样式"的安全收益。

---

## 4. 落地清单（待 ADR 接受后，拆成可审查的小 PR）

- `contract/schema/generic.section.schema.json`：**已落盘**（含 `sectionId`/`title` + role 枚举）；本 ADR 落地时须校验 §2.3 三模板对其结构的覆盖、并确认 role 枚举与 ADR-001 §3.6 一致（防漂移）。
- **客户端卡片组件骨架**：为首批 typed schema（grades / notice / schedule）各实现最小渲染组件。
- **generic 三模板组件**：键值列表 / 简单表格 / 分节列表，消费 generic schema 产出 + role 枚举。
- **主题 token 系统**：role→样式映射的初版实现（跟随 Flutter ThemeData）。
- **端到端验证**：adapter 产出 → 标准 schema → 客户端正确选择组件 → 渲染。
