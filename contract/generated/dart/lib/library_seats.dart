// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class LibrarySeats {
  const LibrarySeats({
    this.items,
  });

  /// 图书馆座位列表；省略表示源站不提供座位数据。
  final List<LibrarySeatsItems>? items;
}

class LibrarySeatsItems {
  const LibrarySeatsItems({
    this.library,
    this.floor,
    this.seatId,
    this.status,
    this.availableFrom,
    this.availableUntil,
  });

  /// 座位所在图书馆；省略表示源站不提供。
  final String? library;
  /// 座位所在楼层；省略表示源站不提供。
  final String? floor;
  /// 座位的校内作用域标识；省略表示源站不提供。
  final String? seatId;
  /// 座位状态：可用、已占用、已预约或未知；省略表示源站不提供。
  final String? status;
  /// 座位可用时段的开始时刻，RFC3339/UTC；省略表示源站不提供。
  final String? availableFrom;
  /// 座位可用时段的结束时刻，RFC3339/UTC；省略表示源站不提供。
  final String? availableUntil;
}
