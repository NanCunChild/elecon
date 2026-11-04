// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class LibrarySearch {
  const LibrarySearch({
    required this.query,
    required this.page,
    required this.size,
    required this.hasNext,
    this.total,
    required this.items,
  });

  /// 书目关键词；去除首尾空白后非空。
  final String query;
  /// 页码，从1开始。
  final int page;
  /// 每页书目数，1至50。
  final int size;
  /// 是否还有下一页；源站无总数时由满页推断。
  final bool hasNext;
  /// 总书目数；源站未提供则省略。
  final int? total;
  /// 当前页书目；不表示个人借阅。
  final List<LibrarySearchItems> items;
}

class LibrarySearchItems {
  const LibrarySearchItems({
    required this.bookId,
    required this.title,
    this.author,
    this.isbn,
    this.publisher,
    this.callNumber,
  });

  /// 同源书目记录ID；不是借阅条码。
  final String bookId;
  /// 书名。
  final String title;
  /// 作者；来源未提供则省略。
  final String? author;
  /// ISBN；来源未提供则省略。
  final String? isbn;
  /// 出版社；来源未提供则省略。
  final String? publisher;
  /// 索书号；来源未提供则省略。
  final String? callNumber;
}
