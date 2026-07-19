// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface ScheduleWeek {
  term: string;
  academicYear?: string;
  termStartDate?: string;
  termEndDate?: string;
  teachingWeekStart?: string;
  teachingWeekEnd?: string;
  weekType?: "teaching" | "exam" | "holiday" | "unknown";
  updatedAt?: string;
  sourceSystem?: string;
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
  date?: string;
  timeStart?: string;
  timeEnd?: string;
  campus?: string;
  building?: string;
  room?: string;
  roomCapacity?: number;
  courseNature?: string;
  classNo?: string;
  language?: string;
  courseUrl?: string;
  group?: string;
  onlineUrl?: string;
  meetingNumberPresent?: boolean;
  meetingPasswordPresent?: boolean;
  changeType?: "none" | "rescheduled" | "cancelled" | "makeup" | "substitute" | "temporaryRoom" | "unknown";
  changeReason?: string;
  weekExceptions?: number[];
  teacher?: string;
  location?: string;
  weeks?: number[];
}
