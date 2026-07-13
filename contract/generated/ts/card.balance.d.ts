// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface CardBalance {
  cardNumber: string;
  balance: CardBalanceBalance;
  lastTransaction?: CardBalanceLastTransaction;
}

export interface CardBalanceBalance {
  /** 最小货币单位，如分 */
  amountMinor: number;
  currency: string;
}

export interface CardBalanceLastTransaction {
  amountMinor?: number;
  currency?: string;
  time?: string;
  merchant?: string;
}
