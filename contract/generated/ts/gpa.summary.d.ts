// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface GpaSummary {
  /** 学校官方绩点。其量纲由 gradePointScale 界定；缺失表示来源未提供。 */
  gpa?: number;
  /** gpa 所用的校本绩点尺度（满分档），取值与 elecon.grades.list 的同名字段一致。缺失/unknown/other 时本体不得把该数当作绩点展示（无量纲的绩点无法判读，ADR-001 §3.5）。注意本字段只界定量纲，**不保证同制式的数可跨校比较**——换算表本身是校本的。 */
  gradePointScale?: "4.0" | "4.3" | "4.5" | "5.0" | "other" | "unknown";
  /** 已获得学分（通过课程的学分和）；缺失表示来源未提供。 */
  earnedCredits?: number;
  /** 已修读学分（含未通过）；缺失表示来源未提供。 */
  attemptedCredits?: number;
  /** 学校给出的排名，从 1 起；缺失表示来源未提供或学校不公布。 */
  rank?: number;
  /** 排名的总人数基数；缺失表示来源未提供。与 rank 配对解读，单独出现无意义。 */
  rankTotal?: number;
  /** 本汇总覆盖的范围，由来源定义（如某学期标识、"全部"、"主修"）；缺失表示来源未限定范围。本体不解析其语义，原样展示。 */
  window?: string;
  /** 汇总数据更新时间，RFC3339/UTC；缺失表示来源未提供。 */
  updatedAt?: string;
}
