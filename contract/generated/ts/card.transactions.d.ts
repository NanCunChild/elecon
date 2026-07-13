// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface CardTransactions {
  cardNumber: string;
  items: CardTransactionsItems[];
}

export interface CardTransactionsItems {
  time: string;
  /** 最小货币单位（如分），非负；收支方向由 direction 表示 */
  amountMinor: number;
  currency: string;
  /** debit=支出 credit=充值/入账 */
  direction: "debit" | "credit";
  merchant?: string;
  /** 本笔交易后余额（最小货币单位）；可选 */
  balanceAfterMinor?: number;
  /** 交易类型原文/归类；可选 */
  type?: string;
}
