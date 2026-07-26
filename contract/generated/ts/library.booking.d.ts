// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface LibraryBooking {
  /** 预约记录列表；省略表示源站不提供预约记录。 */
  items?: LibraryBookingItems[];
}

export interface LibraryBookingItems {
  /** 预约记录的校内作用域标识；省略表示源站不提供。 */
  id?: string;
  /** 预约所在图书馆；省略表示源站不提供。 */
  library?: string;
  /** 预约所在房间或区域；省略表示源站不提供。 */
  room?: string;
  /** 预约座位的校内作用域标识；省略表示源站不提供。 */
  seatId?: string;
  /** 预约开始时刻，RFC3339/UTC；省略表示源站不提供。 */
  startAt?: string;
  /** 预约结束时刻，RFC3339/UTC；省略表示源站不提供。 */
  endAt?: string;
  /** 预约状态：已预约、已取消、已签到、已过期或未知；省略表示源站不提供。 */
  status?: "reserved" | "cancelled" | "checkedIn" | "expired" | "unknown";
}
