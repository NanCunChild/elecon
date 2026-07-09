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
    required this.borrowedAt,
    required this.dueAt,
    this.renewCount,
    this.overdue,
  });

  final String bookId;
  final String title;
  final String? author;
  final String borrowedAt;
  final String dueAt;
  final int? renewCount;
  final bool? overdue;
}
