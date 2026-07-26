// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface ScheduleWeek {
  /** 学期标识，如 2025-2026-2。 */
  term: string;
  /** 课表所属学年；缺失表示来源未提供。 */
  academicYear?: string;
  /** 学期开始日，格式为 YYYY-MM-DD；缺失表示来源未提供。 */
  termStartDate?: string;
  /** 学期结束日，格式为 YYYY-MM-DD；缺失表示来源未提供。 */
  termEndDate?: string;
  /** 本教学周开始日，格式为 YYYY-MM-DD；缺失表示来源未提供。 */
  teachingWeekStart?: string;
  /** 本教学周结束日，格式为 YYYY-MM-DD；缺失表示来源未提供。 */
  teachingWeekEnd?: string;
  /** 周次类型：教学周、考试周、假期或未知；缺失表示来源未提供。 */
  weekType?: "teaching" | "exam" | "holiday" | "unknown";
  /** 课表数据更新时间，RFC3339/UTC；缺失表示来源未提供。 */
  updatedAt?: string;
  /** 课表数据的来源系统；缺失表示来源未提供。 */
  sourceSystem?: string;
  /** 教学周序号，从 1 开始。 */
  week: number;
  /** 本周按星期组织的课表。 */
  days: ScheduleWeekDays[];
}

export interface ScheduleWeekDays {
  /** 星期序号，1 至 7。 */
  dayOfWeek: number;
  /** 当天的课程时段列表。 */
  slots: ScheduleWeekDaysSlots[];
}

export interface ScheduleWeekDaysSlots {
  /** 课程开始节次标签。 */
  start: string;
  /** 课程结束节次标签。 */
  end: string;
  /** 课程名称。 */
  courseName: string;
  /** 校内作用域的课程标识；缺失表示来源未提供。 */
  courseId?: string;
  /** 本次课程的日历日，格式为 YYYY-MM-DD；缺失表示来源未提供。 */
  date?: string;
  /** 课程开始墙钟时间或节次标签；缺失表示来源未提供。 */
  timeStart?: string;
  /** 课程结束墙钟时间或节次标签；缺失表示来源未提供。 */
  timeEnd?: string;
  /** 上课校区；缺失表示来源未提供。 */
  campus?: string;
  /** 上课楼栋；缺失表示来源未提供。 */
  building?: string;
  /** 上课教室；缺失表示来源未提供。 */
  room?: string;
  /** 教室容量，单位为人数；缺失表示来源未提供。 */
  roomCapacity?: number;
  /** 学校定义的课程性质；缺失表示来源未提供。 */
  courseNature?: string;
  /** 教学班号；缺失表示来源未提供。 */
  classNo?: string;
  /** 课程教学语言；缺失表示来源未提供。 */
  language?: string;
  /** 课程页面链接；缺失表示来源未提供。 */
  courseUrl?: string;
  /** 合班或分组信息；缺失表示来源未提供。 */
  group?: string;
  /** 线上课程地址；缺失表示来源未提供。 */
  onlineUrl?: string;
  /** 来源是否提供会议号；仅表示是否存在，不包含会议号值。 */
  meetingNumberPresent?: boolean;
  /** 来源是否提供会议密码；仅表示是否存在，不包含密码值。 */
  meetingPasswordPresent?: boolean;
  /** 课程变更类型：无变更、调课、停课、补课、代课、临时教室或未知；缺失表示来源未提供。 */
  changeType?: "none" | "rescheduled" | "cancelled" | "makeup" | "substitute" | "temporaryRoom" | "unknown";
  /** 课程安排变更原因；缺失表示来源未提供。 */
  changeReason?: string;
  weekExceptions?: number[];
  /** 授课教师；缺失表示来源未提供。 */
  teacher?: string;
  /** 来源提供的非结构化上课地点；缺失表示来源未提供。 */
  location?: string;
  /** 该课程实际上课的教学周序号列表；缺失表示来源未提供。 */
  weeks?: number[];
}
