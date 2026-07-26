// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface LibrarySeats {
  /** 图书馆座位列表；省略表示源站不提供座位数据。 */
  items?: LibrarySeatsItems[];
}

export interface LibrarySeatsItems {
  /** 座位所在图书馆；省略表示源站不提供。 */
  library?: string;
  /** 座位所在楼层；省略表示源站不提供。 */
  floor?: string;
  /** 座位的校内作用域标识；省略表示源站不提供。 */
  seatId?: string;
  /** 座位状态：可用、已占用、已预约或未知；省略表示源站不提供。 */
  status?: "available" | "occupied" | "reserved" | "unknown";
  /** 座位可用时段的开始时刻，RFC3339/UTC；省略表示源站不提供。 */
  availableFrom?: string;
  /** 座位可用时段的结束时刻，RFC3339/UTC；省略表示源站不提供。 */
  availableUntil?: string;
}
