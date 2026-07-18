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
  role: "identifier" | "label" | "status" | "datetime" | "deadline" | "amount" | "quantity" | "link" | "unknown";
  value: string | number | boolean | unknown | GenericSectionFieldsValue;
}

export interface GenericSectionTable {
  columns: GenericSectionTableColumns[];
  rows: string | number | boolean | unknown | GenericSectionTableRows[][];
}

export interface GenericSectionFieldsValue {
  /** 最小货币单位，如分 */
  amountMinor: number;
  currency: string;
}

export interface GenericSectionTableColumns {
  label: string;
  role: "identifier" | "label" | "status" | "datetime" | "deadline" | "amount" | "quantity" | "link" | "unknown";
}

export interface GenericSectionTableRows {
  /** 最小货币单位，如分 */
  amountMinor: number;
  currency: string;
}
