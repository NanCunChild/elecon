// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface CalendarAcademic {
  /** 校历所属学期标识；缺失表示来源未提供学期。 */
  term?: string;
  /** 学期开始日，格式为 YYYY-MM-DD；缺失表示来源未提供。 */
  startDate?: string;
  /** 学期结束日，格式为 YYYY-MM-DD；缺失表示来源未提供。 */
  endDate?: string;
  /** 当前教学周序号，从 1 开始；缺失表示来源未提供或无法确定。 */
  currentWeek?: number;
  /** 校历中的节假日条目列表；缺失表示来源未提供。 */
  holidays?: CalendarAcademicHolidays[];
}

export interface CalendarAcademicHolidays {
  /** 条目对应的日历日，格式为 YYYY-MM-DD。 */
  date: string;
  /** 节假日名称。 */
  name: string;
  /** 该日是否按教学日安排；缺失表示来源未提供此判断。 */
  isTeachingDay?: boolean;
}
