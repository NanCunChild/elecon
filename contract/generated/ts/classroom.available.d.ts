// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface ClassroomAvailable {
  /** 实际采用的查询日历日，格式为 YYYY-MM-DD；未使用日历日轴时省略。 */
  date?: string;
  /** 实际采用的学期标识；未使用或来源未提供时省略。 */
  term?: string;
  /** 实际采用的教学周序号，从 1 开始；未使用教学周轴时省略。 */
  week?: number;
  /** 实际采用的星期序号，1=周一至 7=周日；未使用时省略。 */
  weekday?: number;
  /** 实际采用的墙钟窗口起点，推荐格式 HH:mm；未使用墙钟窗口时省略。 */
  start?: string;
  /** 实际采用的墙钟窗口终点，推荐格式 HH:mm；未使用墙钟窗口时省略。 */
  end?: string;
  /** IANA 时区；adapter 声明；有墙钟字段时应填 */
  timeZone?: string;
  /** 实际采用的节次窗口起点（含），从 1 开始；未使用节次窗口时省略。 */
  sectionStart?: number;
  /** 实际采用的节次窗口终点（含），从 1 开始；未使用节次窗口时省略。 */
  sectionEnd?: number;
  /** 空教室数据的来源系统名称或标识；缺失表示来源未提供。 */
  sourceSystem?: string;
  /** 空教室数据在来源系统中的更新时间，格式为 RFC3339/UTC；缺失表示来源未提供。 */
  updatedAt?: string;
  /** 符合查询条件的教室列表；无匹配教室时可为空数组。 */
  items?: ClassroomAvailableItems[];
}

export interface ClassroomAvailableItems {
  /** 教室所属校区；缺失表示来源未提供。 */
  campus?: string;
  /** 教学楼展示名；禁止空串；未知填 "-" */
  building: string;
  /** 教学楼在校内系统中的标识或代码；缺失表示来源未提供。 */
  buildingId?: string;
  /** 教室展示名；禁止空串；未知填 "-" */
  room: string;
  /** 教室在校内系统中的标识；缺失表示来源未提供。 */
  roomId?: string;
  /** 楼层，字符串以兼容「B1」「东3」等 */
  floor?: string;
  /** 教室容纳人数，单位为人；缺失表示来源未提供。 */
  capacity?: number;
  /** 教室设备名称列表；缺失表示来源未提供设备信息。 */
  equipment?: string[];
  /** 在查询窗口上的聚合占用；无窗口则「当日是否曾占用」由 adapter 定义并尽量文档化 */
  occupied?: boolean;
  /** available=窗口内全空闲；occupied=窗口内全占用；partial=窗口内部分节次占用；unknown=无法判定 */
  status?: "available" | "occupied" | "partial" | "unknown";
  /** 分节占用；缺失=该校不提供节次粒度；至多 24 节 */
  sections?: ClassroomAvailableItemsSections[];
}

export interface ClassroomAvailableItemsSections {
  /** 节次序号，从 1 开始，最大为 24。 */
  index: number;
  /** 该节次是否被占用。 */
  occupied: boolean;
  /** 展示用，如「第3节」 */
  label?: string;
  /** 该节墙钟起点，推荐 HH:mm；解释时区见顶栏 timeZone */
  timeStart?: string;
  /** 该节墙钟终点，推荐 HH:mm */
  timeEnd?: string;
}
