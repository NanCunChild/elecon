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
  /** 学校脚本实际采用的字段值；缺失表示来源不提供回显，不可猜测为请求原值。 */
  appliedFilters?: Record<string, string | number | boolean | string[] | ClassroomAvailableAppliedFiltersValue>;
  /** 实际查询条件范围的完整性证据；缺失表示完整性未知，不是完整或空结果。 */
  coverage?: ClassroomAvailableCoverage;
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
  /** 已知绝对时段，左闭右开；同教室不得重叠，结束晚于开始；缺口为未知，不从节间或无课程推断开放。省略表示仅有旧聚合/节次数据。 */
  intervals?: ClassroomAvailableItemsIntervals[];
  /** 学校教室类型；缺失表示未知，不生成通用默认类型。 */
  roomType?: ClassroomAvailableItemsRoomType;
  /** 教学布置的座位容量，单位人；缺失表示未知，不能以0代替或继承考试容量。 */
  teachingCapacity?: number;
  /** 考试布置的座位容量，单位人；缺失表示未知，不能以0代替或继承教学容量。 */
  examCapacity?: number;
}

export interface ClassroomAvailableAppliedFiltersValue {
  /** 同日开始墙钟时刻，HH:mm；必须早于end。 */
  start: string;
  /** 同日结束墙钟时刻，HH:mm；不含该时刻。 */
  end: string;
}

export interface ClassroomAvailableCoverage {
  /** 是否已完整覆盖实际采用条件的查询范围；true不等于查询全校，false表示仅部分结果。 */
  complete: boolean;
  /** 可选纯文本范围和不完整原因说明；不用于推断未返回教室的状态。 */
  description?: string;
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

export interface ClassroomAvailableItemsIntervals {
  /** 区间起点（含），RFC3339/UTC；必须是查询日对应的真实时刻。 */
  startAt: string;
  /** 区间终点（不含），RFC3339/UTC；必须晚于 startAt。 */
  endAt: string;
  /** 本区间无占用记录、占用或无法确认；available 不保证实际开门或允许使用。 */
  status: "available" | "occupied" | "unknown";
  /** 学校脚本提供的状态依据或原因，纯文本；缺失表示来源未提供，宿主不得猜测。 */
  reason?: string;
}

export interface ClassroomAvailableItemsRoomType {
  /** 学校提供的教室类型名称，不据名称推断设备或用途权限。 */
  label: string;
  /** 学校作用域的类型代码；缺失表示来源未提供，不能以label替代。 */
  code?: string;
}
