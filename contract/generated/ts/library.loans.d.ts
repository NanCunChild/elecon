// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface LibraryLoans {
  items: LibraryLoansItems[];
}

export interface LibraryLoansItems {
  /** 馆藏条码/记录 id；无独立 id 时可用条码。禁止空串。 */
  bookId: string;
  title: string;
  author?: string;
  callNumber?: string;
  /** 馆藏位置/架位描述 */
  location?: string;
  /** 分馆/校区馆 */
  branch?: string;
  /** 借出时刻 RFC3339/UTC。源站仅有日历日时，adapter 归一为该日 00:00:00Z（ADR-001 §3.4）。 */
  borrowedAt: string;
  /** 应还时刻 RFC3339/UTC。源站仅有日历日时，adapter 归一为该日 23:59:59Z 或次日 00:00:00Z（同校内一致即可，须在 adapter 注释固定）。 */
  dueAt: string;
  renewCount?: number;
  renewalMax?: number;
  renewable?: boolean;
  overdue?: boolean;
  overdueFee?: LibraryLoansItemsOverdueFee;
  reserved?: boolean;
  pickupDeadline?: string;
  renewalDeadline?: string;
  returnConfirmed?: boolean;
}

export interface LibraryLoansItemsOverdueFee {
  amountMinor: number;
  currency: string;
}
