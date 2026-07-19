// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface ResearchIncome {
  items?: ResearchIncomeItems[];
}

export interface ResearchIncomeItems {
  month?: string;
  amountMinor?: number;
  currency?: string;
  status?: "pending" | "paid" | "failed" | "unknown";
  source?: string;
}
