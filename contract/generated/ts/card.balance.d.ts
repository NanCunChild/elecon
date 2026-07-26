// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface CardBalance {
  /** 校内作用域的一卡通卡号。 */
  cardNumber: string;
  /** 脱敏后的一卡通卡号；可选，缺失表示学校不提供。 */
  cardNumberMasked?: string;
  /** 一卡通卡片类型；可选，缺失表示学校不提供。 */
  cardType?: string;
  /** 一卡通账户类型；可选，缺失表示学校不提供。 */
  accountType?: string;
  /** 一卡通所属校区；可选，缺失表示学校不提供。 */
  campus?: string;
  /** 余额所属钱包；可选，缺失表示学校不提供。 */
  wallet?: string;
  /** 一卡通状态：active=正常，frozen=冻结，lost=挂失，cancelled=注销，unknown=未知；可选，缺失表示学校不提供。 */
  status?: "active" | "frozen" | "lost" | "cancelled" | "unknown";
  balanceUpdatedAt?: string;
  snapshotAt?: string;
  errorStatus?: "failed" | "pending" | "unknown";
  /** 一卡通当前余额，使用整数最小货币单位和三字母货币码表示。 */
  balance: CardBalanceBalance;
  /** 最近一笔一卡通交易摘要；可选，缺失表示学校不提供。 */
  lastTransaction?: CardBalanceLastTransaction;
}

export interface CardBalanceBalance {
  /** 最小货币单位，如分 */
  amountMinor: number;
  /** ISO 4217 三字母大写货币码，如 CNY。 */
  currency: string;
}

export interface CardBalanceLastTransaction {
  /** 该笔交易金额的最小货币单位整数（如人民币分）；不用浮点。 */
  amountMinor?: number;
  /** 该笔交易的 ISO 4217 三字母大写货币码，如 CNY。 */
  currency?: string;
  time?: string;
  /** 该笔交易的商户名称；可选，缺失表示学校不提供。 */
  merchant?: string;
}
