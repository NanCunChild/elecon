// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface EnergyUsage {
  /** 水电用量记录列表；可选，缺失表示学校不提供。 */
  items?: EnergyUsageItems[];
}

export interface EnergyUsageItems {
  /** 用量记录所属校区；可选，缺失表示学校不提供。 */
  campus?: string;
  /** 用量记录所属宿舍楼；可选，缺失表示学校不提供。 */
  dormitory?: string;
  /** 用量记录所属房间；可选，缺失表示学校不提供。 */
  room?: string;
  /** 能源类型：water=水，electricity=电，unknown=未知；可选，缺失表示学校不提供。 */
  type?: "water" | "electricity" | "unknown";
  /** 计量表读数，单位由同级 unit 指定；可选，缺失表示学校不提供。 */
  reading?: number;
  /** 统计时段内的用量，单位由同级 unit 指定；可选，缺失表示学校不提供。 */
  usage?: number;
  /** 读数和用量的计量单位；可选，缺失表示学校不提供。 */
  unit?: string;
  /** 用量统计时段的起始时刻，RFC3339/UTC；可选，缺失表示学校不提供。 */
  from?: string;
  /** 用量统计时段的结束时刻，RFC3339/UTC；可选，缺失表示学校不提供。 */
  to?: string;
}
