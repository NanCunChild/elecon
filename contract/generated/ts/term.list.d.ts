// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface TermList {
  /** 当前学期标识；缺失表示来源未提供或无法确定。 */
  currentTerm?: string;
  /** 学期条目列表；缺失表示来源未提供学期列表。 */
  items?: TermListItems[];
}

export interface TermListItems {
  /** 学期在校内系统中的标识。 */
  id: string;
  /** 学期展示名称。 */
  name: string;
  /** 学期所属学年；缺失表示来源未提供。 */
  academicYear?: string;
  /** 学期开始日，格式为 YYYY-MM-DD；缺失表示来源未提供。 */
  startDate?: string;
  /** 学期结束日，格式为 YYYY-MM-DD；缺失表示来源未提供。 */
  endDate?: string;
  /** 学期教学周总数，单位为周；缺失表示来源未提供。 */
  teachingWeeks?: number;
}
