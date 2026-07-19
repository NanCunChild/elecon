// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class LibrarySeats {
  const LibrarySeats({
    this.items,
  });

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

  final String? library;
  final String? floor;
  final String? seatId;
  final String? status;
  final String? availableFrom;
  final String? availableUntil;
}
