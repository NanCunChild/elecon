// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface DormHealth {
  /** 宿舍健康指标列表；可选，缺失表示学校不提供。 */
  items?: DormHealthItems[];
}

export interface DormHealthItems {
  /** 健康指标名称；可选，缺失表示学校不提供。 */
  metric?: string;
  /** 指标测量值，单位由同级 unit 指定；可选，缺失表示学校不提供。 */
  value?: number;
  /** 指标测量值的单位；可选，缺失表示学校不提供。 */
  unit?: string;
  /** 指标测量时刻，RFC3339/UTC；可选，缺失表示学校不提供。 */
  measuredAt?: string;
  /** 指标状态：normal=正常，abnormal=异常，unknown=未知；可选，缺失表示学校不提供。 */
  status?: "normal" | "abnormal" | "unknown";
}
