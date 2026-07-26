// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface ResearchIncome {
  /** 科研收入记录列表；可选，缺失表示学校不提供。 */
  items?: ResearchIncomeItems[];
}

export interface ResearchIncomeItems {
  /** 收入归属月份；字符串格式未由当前契约限定。可选，缺失表示学校不提供。 */
  month?: string;
  /** 科研收入金额的最小货币单位整数（如人民币分）；不用浮点。 */
  amountMinor?: number;
  /** 收入金额的 ISO 4217 三字母大写货币码，如 CNY。 */
  currency?: string;
  /** 收入状态：pending=待处理，paid=已支付，failed=失败，unknown=未知；可选，缺失表示学校不提供。 */
  status?: "pending" | "paid" | "failed" | "unknown";
  /** 科研收入来源；可选，缺失表示学校不提供。 */
  source?: string;
}
