// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class LibraryLoans {
  const LibraryLoans({
    required this.items,
  });

  final List<LibraryLoansItems> items;
}

class LibraryLoansItems {
  const LibraryLoansItems({
    required this.bookId,
    required this.title,
    this.author,
    this.callNumber,
    this.location,
    this.branch,
    required this.borrowedAt,
    required this.dueAt,
    this.renewCount,
    this.renewalMax,
    this.renewable,
    this.overdue,
    this.overdueFee,
    this.reserved,
    this.pickupDeadline,
    this.renewalDeadline,
    this.returnConfirmed,
  });

  /// 馆藏条码/记录 id；无独立 id 时可用条码。禁止空串。
  final String bookId;
  final String title;
  final String? author;
  final String? callNumber;
  /// 馆藏位置/架位描述
  final String? location;
  /// 分馆/校区馆
  final String? branch;
  /// 借出时刻 RFC3339/UTC。源站仅有日历日时，adapter 归一为该日 00:00:00Z（ADR-001 §3.4）。
  final String borrowedAt;
  /// 应还时刻 RFC3339/UTC。源站仅有日历日时，adapter 归一为该日 23:59:59Z 或次日 00:00:00Z（同校内一致即可，须在 adapter 注释固定）。
  final String dueAt;
  final int? renewCount;
  final int? renewalMax;
  final bool? renewable;
  final bool? overdue;
  final LibraryLoansItemsOverdueFee? overdueFee;
  final bool? reserved;
  final String? pickupDeadline;
  final String? renewalDeadline;
  final bool? returnConfirmed;
}

class LibraryLoansItemsOverdueFee {
  const LibraryLoansItemsOverdueFee({
    required this.amountMinor,
    required this.currency,
  });

  final int amountMinor;
  final String currency;
}
