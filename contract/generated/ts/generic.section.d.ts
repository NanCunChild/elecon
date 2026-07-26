// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface GenericSection {
  /** 本节稳定标识（校内作用域字符串） */
  sectionId: string;
  /** 本节标题，纯文本，无样式 */
  title: string;
  /** 带标签字段 / 键值组 */
  fields?: GenericSectionFields[];
  /** 简单表格（可选） */
  table?: GenericSectionTable;
}

export interface GenericSectionFields {
  /** 字段标签，纯文本 */
  label: string;
  /** 字段的语义角色提示；本体据此决定渲染。 */
  role: "identifier" | "label" | "status" | "datetime" | "deadline" | "amount" | "quantity" | "link" | "unknown";
  /** 字段的归一化原始值；格式由 role 约定。 */
  value: string | number | boolean | unknown | GenericSectionFieldsValue;
}

export interface GenericSectionTable {
  /** 表格列定义，顺序与每行的数据值一致。 */
  columns: GenericSectionTableColumns[];
  /** 表格数据行；每行各值按 columns 的顺序排列。 */
  rows: string | number | boolean | unknown | GenericSectionTableRows[][];
}

export interface GenericSectionFieldsValue {
  /** 最小货币单位，如分 */
  amountMinor: number;
  /** ISO 4217 三位大写货币码，如 CNY。 */
  currency: string;
}

export interface GenericSectionTableColumns {
  /** 表格列标题，纯文本。 */
  label: string;
  /** 该列的语义角色提示；本体据此决定渲染。 */
  role: "identifier" | "label" | "status" | "datetime" | "deadline" | "amount" | "quantity" | "link" | "unknown";
}

export interface GenericSectionTableRows {
  /** 最小货币单位，如分 */
  amountMinor: number;
  /** ISO 4217 三位大写货币码，如 CNY。 */
  currency: string;
}
