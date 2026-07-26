// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface LibraryLoans {
  /** 当前借阅记录列表。 */
  items: LibraryLoansItems[];
}

export interface LibraryLoansItems {
  /** 馆藏条码/记录 id；无独立 id 时可用条码。禁止空串。 */
  bookId: string;
  /** 书名。 */
  title: string;
  /** 作者；省略表示源站不提供。 */
  author?: string;
  /** 馆藏索书号；省略表示源站不提供。 */
  callNumber?: string;
  /** 馆藏位置/架位描述 */
  location?: string;
  /** 分馆/校区馆 */
  branch?: string;
  /** 借出时刻 RFC3339/UTC。源站仅有日历日时，adapter 归一为该日 00:00:00Z（ADR-001 §3.4）。 */
  borrowedAt: string;
  /** 应还时刻 RFC3339/UTC。源站仅有日历日时，adapter 归一为该日 23:59:59Z 或次日 00:00:00Z（同校内一致即可，须在 adapter 注释固定）。 */
  dueAt: string;
  /** 已续借次数；省略表示源站不提供。 */
  renewCount?: number;
  /** 允许续借的最大次数；省略表示源站不提供。 */
  renewalMax?: number;
  /** 当前是否允许续借；省略表示源站不提供。 */
  renewable?: boolean;
  /** 当前是否逾期；省略表示源站不提供。 */
  overdue?: boolean;
  /** 逾期费用；省略表示源站不提供。 */
  overdueFee?: LibraryLoansItemsOverdueFee;
  /** 该馆藏当前是否处于预约状态；省略表示源站不提供。 */
  reserved?: boolean;
  /** 预约取书截止时刻，RFC3339/UTC；省略表示源站不提供。 */
  pickupDeadline?: string;
  /** 续借办理截止时刻，RFC3339/UTC；省略表示源站不提供。 */
  renewalDeadline?: string;
  /** 归还是否已被图书馆系统确认；省略表示源站不提供。 */
  returnConfirmed?: boolean;
}

export interface LibraryLoansItemsOverdueFee {
  /** 逾期费用的最小货币单位整数值，如人民币分；不用浮点。 */
  amountMinor: number;
  /** 逾期费用的 ISO 4217 三位大写货币码，如 CNY。 */
  currency: string;
}
