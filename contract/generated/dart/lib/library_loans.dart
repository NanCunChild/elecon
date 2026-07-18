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
    this.overdue,
    this.renewalMax,
    this.renewable,
    this.overdueFee,
    this.reserved,
    this.pickupDeadline,
    this.renewalDeadline,
    this.returnConfirmed,
  });

  final String bookId;
  final String title;
  final String? author;
  final String? callNumber;
  final String? location;
  final String? branch;
  final String borrowedAt;
  final String dueAt;
  final int? renewCount;
  final bool? overdue;
  final int? renewalMax;
  final bool? renewable;
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
