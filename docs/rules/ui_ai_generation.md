# 规则 · AI 生成 Flutter UI

配合 [`AGENTS.md`](../../AGENTS.md) 与 [`docs/rules/ai_coding.md`](ai_coding.md) 阅读，约束在后者基础上**叠加**。立场：**UI 可以大量交给 AI 生成，但生成必须落在 [ADR-004](../adr/adr_004_ui_sdui.md) 的框内**——elecon 不做完整 SDUI（无 Widget-tree JSON），UI = 客户端硬编码的**有界卡片组件集** + generic 域固定模板。AI 自由发挥页面布局会直接和这套架构打架。

视觉基线：**Material 3**（M3 的 token 化主题契合 ADR-004「token 随主题变、组件不感知」）。

> **跟随 ADR-004**：ADR-004 当前为**草案（Proposed）**。本规则跟随它；若 ADR-004 被修订或否决，本文同步调整。本文中标「ADR-004 §…」的均为 ADR 原文约束，标「（规则层）」的为本规则在 ADR 之上的额外加强。

---

## 1. 四条边界（生成前先框死）

1. **生成「有界组件集」，不是自由页面布局。** 可生成的只有两类（ADR-004 §2.1/§2.2）：
   - **typed 域卡片**：每个 typed schema 一个主卡片组件（+ 可选详情视图）——grades / schedule / notice / card / library；
   - **generic 域模板**：一组**固定**模板（键值列表 / 简单表格 / 分节列表），据数据形状 + 角色枚举自动选模板。
   - ❌ 不生成「按某个学校 / 某个页面定制」的一次性布局；新增 typed 卡片 = 新增 schema = 走 ADR 慢车道 + 发版（ADR-004 §2.4），不在 UI 生成范围内顺手加。

2. **输入契约是标准 schema，不是自由字段。** 组件只是 `emits.schema` 的**渲染器**：照 `contract/` 的 schema 生成，**不臆造字段、不改字段含义**。"驱动"发生在数据层（schema 选组件），不在渲染层。schema 变更属契约改动 → 红线 #6，停手开 ADR。

3. **样式全走 design token + 角色枚举，不硬编码。** 颜色 / 间距 / 字号经 token（M3 `ColorScheme.fromSeed` + `ThemeData`），role → 主题样式映射收口到 token 层，组件不感知具体主题。ADR-004 §2.4 把「深色 / 浅色 / **高对比度**」列为可切换主题；**（规则层）** 本规则要求生成的组件不得破坏任一主题的可切换性（即一律走 token、不硬编码），使高对比度等无障碍主题始终可用。

4. **UI 是不可信侧，永远异步。**
   - ❌ 生成的 UI **绝不接触凭证**的值或等价物（红线 #1）；不引入任何凭证存储 / 透传。
   - ❌ 不让 adapter 输出**驱动 widget 结构**（半可信 adapter 不得驱动渲染，ADR-002）——adapter 只决定"有什么数据"，客户端决定"怎么渲染"。
   - adapter 在背景 isolate、**UI 永远异步**（红线 #7）：组件必须显式处理 **loading / error / empty** 三态，不得假设同步数据。

---

## 2. 产出前自检清单（在 [`ai_coding.md`](ai_coding.md) §1 之上叠加）

- [ ] 生成物属于 §1.1 的两类组件之一（typed 卡片 / generic 模板），**未**夹带一次性页面布局或学校定制。
- [ ] 组件输入严格对齐 `contract/` 标准 schema；**未**新增/改写字段（如需 → 开 schema ADR）。
- [ ] 颜色/间距/字号经 design token；深色 / 浅色 / 高对比度均可切换；**未**硬编码主题值。
- [ ] 组件**未**触碰凭证；**未**让 adapter 输出决定 widget 结构。
- [ ] loading / error / empty 三态齐备；数据按异步消费。
- [ ] generic 长尾数据有模板兜底（无对应 typed 卡片时不崩、不空白）。
- [ ] 附 widget 测试：覆盖 adapter 产出 → 标准 schema → 选中正确组件 → 渲染（ADR-004 §端到端验证）；测试数据脱敏。*（当 `client/` UI 工程与 widget 测试框架建立后生效；当前 `client/lib/ui` 尚空，先就绪后补不阻塞首版组件落地。）*

**任一项无法打勾 → 不提交该 UI 改动，改为提出问题或开 ADR。**

---

## 3. 升级信号（出现即停手，交回人工 / 开 ADR）

- 需要新增 typed schema 才能渲染某数据（= 契约 + 发版决策，ADR-004 §2.4 / 红线 #6）。
- generic 三模板表达不了某数据形状，想加新模板（属 ADR-004 决策面）。
- 想让组件读取 schema 之外的数据，或让 adapter / 服务端下发渲染描述（触 ADR-002 / 完整 SDUI 的被否决方案）。
- UI 需要任何形式的凭证或私密数据（红线 #1）。

这些是 UI 层的"承重墙"决策，由人和 ADR 定，不由一次生成顺手定。
