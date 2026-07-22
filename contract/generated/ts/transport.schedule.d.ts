// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface TransportSchedule {
  /** 班次列表；无班车信息时为空数组（禁止省略 items）。 */
  items?: TransportScheduleItems[];
}

export interface TransportScheduleItems {
  /** 线路名/编号（如「南校区—北校区」） */
  route?: string;
  /** 站点名 */
  stop?: string;
  /** 发车时刻 RFC3339/UTC。源站仅有钟点时，adapter 归一到 operatingDate 当日（ADR-001 §3.4）。 */
  departureAt?: string;
  /** 运营日历日 YYYY-MM-DD（本地校历日，不含时区）。 */
  operatingDate?: string;
  /** 班次状态；源站无对应信息时用 unknown（禁止臆造 scheduled）。 */
  status?: "scheduled" | "delayed" | "cancelled" | "unknown";
}
