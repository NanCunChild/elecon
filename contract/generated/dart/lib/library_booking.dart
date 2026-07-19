// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class LibraryBooking {
  const LibraryBooking({
    this.items,
  });

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

  final String? id;
  final String? library;
  final String? room;
  final String? seatId;
  final String? startAt;
  final String? endAt;
  final String? status;
}
