// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface ClassroomAvailable {
  date?: string;
  term?: string;
  week?: number;
  weekday?: number;
  start?: string;
  end?: string;
  /** IANA 时区；adapter 声明；有墙钟字段时应填 */
  timeZone?: string;
  sectionStart?: number;
  sectionEnd?: number;
  sourceSystem?: string;
  updatedAt?: string;
  items?: ClassroomAvailableItems[];
}

export interface ClassroomAvailableItems {
  campus?: string;
  /** 教学楼展示名；禁止空串；未知填 "-" */
  building: string;
  buildingId?: string;
  /** 教室展示名；禁止空串；未知填 "-" */
  room: string;
  roomId?: string;
  /** 楼层，字符串以兼容「B1」「东3」等 */
  floor?: string;
  capacity?: number;
  equipment?: string[];
  /** 在查询窗口上的聚合占用；无窗口则「当日是否曾占用」由 adapter 定义并尽量文档化 */
  occupied?: boolean;
  /** available=窗口内全空闲；occupied=窗口内全占用；partial=窗口内部分节次占用；unknown=无法判定 */
  status?: "available" | "occupied" | "partial" | "unknown";
  /** 分节占用；缺失=该校不提供节次粒度；至多 24 节 */
  sections?: ClassroomAvailableItemsSections[];
}

export interface ClassroomAvailableItemsSections {
  index: number;
  occupied: boolean;
  /** 展示用，如「第3节」 */
  label?: string;
  /** 该节墙钟起点，推荐 HH:mm；解释时区见顶栏 timeZone */
  timeStart?: string;
  /** 该节墙钟终点，推荐 HH:mm */
  timeEnd?: string;
}
