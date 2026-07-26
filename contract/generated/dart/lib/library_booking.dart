// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class LibraryBooking {
  const LibraryBooking({
    this.items,
  });

  /// 预约记录列表；省略表示源站不提供预约记录。
  final List<LibraryBookingItems>? items;
}

class LibraryBookingItems {
  const LibraryBookingItems({
    this.id,
    this.library,
    this.room,
    this.seatId,
    this.startAt,
    this.endAt,
    this.status,
  });

  /// 预约记录的校内作用域标识；省略表示源站不提供。
  final String? id;
  /// 预约所在图书馆；省略表示源站不提供。
  final String? library;
  /// 预约所在房间或区域；省略表示源站不提供。
  final String? room;
  /// 预约座位的校内作用域标识；省略表示源站不提供。
  final String? seatId;
  /// 预约开始时刻，RFC3339/UTC；省略表示源站不提供。
  final String? startAt;
  /// 预约结束时刻，RFC3339/UTC；省略表示源站不提供。
  final String? endAt;
  /// 预约状态：已预约、已取消、已签到、已过期或未知；省略表示源站不提供。
  final String? status;
}
