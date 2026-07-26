// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface CardTransactions {
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
  /** 交易所属钱包；可选，缺失表示学校不提供。 */
  wallet?: string;
  /** 当前结果页码，从 1 开始；可选，缺失表示该数据源不使用页码分页。 */
  page?: number;
  /** 当前分页的每页条数；可选，缺失表示该数据源不提供。 */
  size?: number;
  cursor?: string;
  /** 符合条件的交易总条数；可选，缺失表示学校不提供。 */
  total?: number;
  /** 是否还有下一批交易；可选，缺失表示学校不提供。 */
  hasNext?: boolean;
  windowStart?: string;
  windowEnd?: string;
  snapshotAt?: string;
  /** 一卡通交易记录列表。 */
  items: CardTransactionsItems[];
}

export interface CardTransactionsItems {
  /** 交易发生时刻，RFC3339/UTC。 */
  time: string;
  /** 校内作用域的交易标识；可选，缺失表示学校不提供。 */
  transactionId?: string;
  /** 交易入账时刻，RFC3339/UTC；可选，缺失表示学校不提供。 */
  postedAt?: string;
  /** 最小货币单位（如分），非负；收支方向由 direction 表示 */
  amountMinor: number;
  /** 交易金额的 ISO 4217 三字母大写货币码，如 CNY。 */
  currency: string;
  /** debit=支出 credit=充值/入账 */
  direction: "debit" | "credit" | "refund" | "reversal" | "freeze" | "transfer" | "subsidy" | "unknown";
  /** 交易商户名称；可选，缺失表示学校不提供。 */
  merchant?: string;
  /** 交易地点；可选，缺失表示学校不提供。 */
  location?: string;
  /** 交易状态：final=已完成，pending=处理中，failed=失败，cancelled=已取消，unknown=未知；可选，缺失表示学校不提供。 */
  status?: "final" | "pending" | "failed" | "cancelled" | "unknown";
  /** 本笔交易后余额（最小货币单位）；可选 */
  balanceAfterMinor?: number;
  /** 交易类型原文/归类；可选 */
  type?: string;
}
