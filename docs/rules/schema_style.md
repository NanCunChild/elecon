# contract/schema 风格与兼容规范

> 适用于 `contract/schema/*.schema.json`（`emits` 结果 schema 与 `params.*` 入参 schema）。
> 契约是承重墙（红线 #6）：改结构须走 ADR；本文只约束**书写风格与既有约定的成文化**，不改变任何字段语义。
> schema 是 Dart/TS 类型的**唯一事实来源**（`tools/src/codegen`），故风格直接决定生成物与前端可读性。

---

## 0. 一句话

**命名即语义、每字段必有 `description`、时刻/日历日格式二分、书写统一 pretty-print。** 兼容面**默认开放**（不 `additionalProperties: false`），拼写错误由 adapter 作者负责。

---

## 1. 结构骨架（每份 schema 必备）

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "elecon.<capability.id>",
  "title": "<中文短标题>",
  "type": "object",
  ...
}
```

- `$schema` 固定 draft 2020-12；`$id` 为 `elecon.` + capability id（点分）。
- 顶层 `type: object`（codegen 只为对象根生成类型）。
- `title` 用中文短语。

## 2. `description`：**每个 `properties` 字段必填**（本次新规）

- **所有** `properties` 下的字段（含嵌套 object / array item 内的字段）**必须**带 `description`。
- 理由：`description` 是**前端展示与 adapter 作者的唯一契约交代**（不引入 `x-` 扩展命名空间，正因它无法向前端交代——见 §5）。
- 写法：一句话说清**含义 + 单位/格式 + 缺失时的约定**。示例：
  ```json
  "amountMinor": { "type": "integer", "minimum": 0, "description": "金额最小货币单位（分）；不用浮点。" }
  ```
- **CI 有牙齿（分级上线）**：`cd tools && npm run codegen -- --check` 始终**枚举**缺 `description` 的字段（`file  路径`）；加 `--require-descriptions` 则**硬失败**（退出码非 0）。
  - 现阶段：backfill 未完成，CI 用不带 flag 的 `--check`（只报告，不打红）。
  - backfill 完成后：CI 切到 `--check --require-descriptions`，缺字段即挡合并。

## 3. 时刻 vs 日历日：命名即语义

既有约定，现成文并**强制**：

| 后缀 | 含义 | `format` | 例 |
|---|---|---|---|
| `*At` | **时刻**（瞬间） | `date-time`（RFC3339/UTC） | `borrowedAt` `updatedAt` `departureAt` |
| `*Date` | **日历日**（无时区） | `date`（`YYYY-MM-DD`） | `startDate` `operatingDate` `termStartDate` |
| `*Deadline` | 截止**时刻** | `date-time` | `pickupDeadline` |

**adapter 归一规则**（落 ADR-001 §3.4，不再散落各处注释）：源站只给日历日、而 schema 字段是 `*At`（date-time）时，adapter 须归一为该日的确定时刻并**在 adapter 内注释固定**同校一致的约定（如借出 `00:00:00Z`、应还 `23:59:59Z`）。

## 4. 公共结构（金额等）

- 金额一律 `{ "amountMinor": integer(分), "currency": "^[A-Z]{3}$" }`，**不用浮点**。
- 现状金额块在多份 schema 内联重复 → 生成 7 个独立类型。**共享具名类型（一份 `Money`）需 codegen 支持一等 `$defs`，属结构改动，另走 ADR-021**；在其落地前，内联块**字段名/约束须逐字节一致**（见本文金额定义），便于日后机械替换。

## 5. 兼容面：`additionalProperties` **默认开放**（刻意决定）

- 结果 `emits` schema **不设** `additionalProperties: false`（默认 `true`）。跨校源站多给的字段静默透传，**最大化跨校 adapter 覆盖面**。
- **拒绝** `x-` 扩展命名空间：它对前端展示无法交代，收益不足以抵消复杂度。
- **拼写错误由 adapter 作者承担**——不靠 schema 收严来兜底拼写；收严的边际收益小。
- `params.*` 入参同理默认开放（入参由本仓构造，风险自控）。

## 6. 书写格式

- **pretty-print，2 空格缩进**；禁止单行压缩整份 schema。
- 短叶子节点可单行（`"x": { "type": "string", "description": "…" }`）；带 `format`/多约束/`required` 的对象展开多行。
- 字段顺序：先 `required` 字段，后可选字段（可读性，非强制）。
- 建议接 `prettier --check` 挡格式分叉。

---

## 附：自检清单（改 schema 前）

- [ ] `$schema`/`$id`/`title`/`type: object` 齐全
- [ ] 每个 `properties` 字段有 `description`（含嵌套）
- [ ] 时刻字段 `*At`→`date-time`、日历日 `*Date`→`date`
- [ ] 金额用 `amountMinor`+`currency`，字段名/约束与 §4 一致
- [ ] 未新增 `additionalProperties: false`、未引入 `x-` 字段
- [ ] pretty-print、2 空格缩进
- [ ] `cd tools && npm run codegen -- --check` 通过（含 description 门）
