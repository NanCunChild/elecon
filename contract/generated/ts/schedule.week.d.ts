// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface ScheduleWeek {
  term: string;
  week: number;
  days: ScheduleWeekDays[];
}

export interface ScheduleWeekDays {
  dayOfWeek: number;
  slots: ScheduleWeekDaysSlots[];
}

export interface ScheduleWeekDaysSlots {
  start: string;
  end: string;
  courseName: string;
  courseId?: string;
  teacher?: string;
  location?: string;
  weeks?: number[];
}
