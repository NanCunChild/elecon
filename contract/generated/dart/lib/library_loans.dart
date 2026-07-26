// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class LibraryLoans {
  const LibraryLoans({
    required this.items,
  });

  /// 当前借阅记录列表。
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
  /// 书名。
  final String title;
  /// 作者；省略表示源站不提供。
  final String? author;
  /// 馆藏索书号；省略表示源站不提供。
  final String? callNumber;
  /// 馆藏位置/架位描述
  final String? location;
  /// 分馆/校区馆
  final String? branch;
  /// 借出时刻 RFC3339/UTC。源站仅有日历日时，adapter 归一为该日 00:00:00Z（ADR-001 §3.4）。
  final String borrowedAt;
  /// 应还时刻 RFC3339/UTC。源站仅有日历日时，adapter 归一为该日 23:59:59Z 或次日 00:00:00Z（同校内一致即可，须在 adapter 注释固定）。
  final String dueAt;
  /// 已续借次数；省略表示源站不提供。
  final int? renewCount;
  /// 允许续借的最大次数；省略表示源站不提供。
  final int? renewalMax;
  /// 当前是否允许续借；省略表示源站不提供。
  final bool? renewable;
  /// 当前是否逾期；省略表示源站不提供。
  final bool? overdue;
  /// 逾期费用；省略表示源站不提供。
  final LibraryLoansItemsOverdueFee? overdueFee;
  /// 该馆藏当前是否处于预约状态；省略表示源站不提供。
  final bool? reserved;
  /// 预约取书截止时刻，RFC3339/UTC；省略表示源站不提供。
  final String? pickupDeadline;
  /// 续借办理截止时刻，RFC3339/UTC；省略表示源站不提供。
  final String? renewalDeadline;
  /// 归还是否已被图书馆系统确认；省略表示源站不提供。
  final bool? returnConfirmed;
}

class LibraryLoansItemsOverdueFee {
  const LibraryLoansItemsOverdueFee({
    required this.amountMinor,
    required this.currency,
  });

  /// 逾期费用的最小货币单位整数值，如人民币分；不用浮点。
  final int amountMinor;
  /// 逾期费用的 ISO 4217 三位大写货币码，如 CNY。
  final String currency;
}
