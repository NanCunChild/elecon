// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface DiningSummary {
  /** 餐饮汇总条目；可选，缺失表示学校不提供。 */
  items?: DiningSummaryItems[];
}

export interface DiningSummaryItems {
  /** 餐饮商户名称；可选，缺失表示学校不提供。 */
  merchant?: string;
  /** 该汇总条目金额的最小货币单位整数（如人民币分）；不用浮点。 */
  amountMinor?: number;
  /** 金额的 ISO 4217 三字母大写货币码，如 CNY。 */
  currency?: string;
  /** 汇总周期；字符串格式未由当前契约限定。可选，缺失表示学校不提供。 */
  period?: string;
  open?: boolean;
}
