// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface ParamsClassroomAvailable {
  /** 查询日历日 YYYY-MM-DD */
  date?: string;
  /** 学期标识，如 2025-2026-2；省略=当前学期（若源站需要） */
  term?: string;
  /** 教学周序号 */
  week?: number;
  /** 星期 1=周一 … 7=周日 */
  weekday?: number;
  /** 校区名称或校内 code（校作用域） */
  campus?: string;
  /** 教学楼展示名；模糊匹配时 adapter 自定，优先用 buildingId */
  building?: string;
  /** 教学楼校内 id/code（如西电 JXLDM） */
  buildingId?: string;
  /** 教室展示名过滤 */
  room?: string;
  /** 教室校内 id */
  roomId?: string;
  /** 窗口起点，推荐 HH:mm（墙钟） */
  start?: string;
  /** 窗口终点，推荐 HH:mm（墙钟） */
  end?: string;
  /** IANA 时区；调用方可选提示；权威声明在 adapter emits */
  timeZone?: string;
  /** 节次窗口起点（含），1-based */
  sectionStart?: number;
  /** 节次窗口终点（含），1-based；须 ≥ sectionStart */
  sectionEnd?: number;
  /** true=只返回在查询窗口内判定为空闲的教室；默认 false=返回楼内对照列表 */
  onlyAvailable?: boolean;
}
