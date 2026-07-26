// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface ProfileMe {
  /** 当前用户姓名；缺失表示来源未提供。 */
  name?: string;
  /** 脱敏后的学号；缺失表示来源未提供。 */
  studentIdMasked?: string;
  /** 当前用户所属院系；缺失表示来源未提供。 */
  department?: string;
  /** 当前用户所学专业；缺失表示来源未提供。 */
  major?: string;
  /** 当前用户所在年级；缺失表示来源未提供。 */
  grade?: string;
  /** 校内身份类型：undergraduate=本科生，graduate=研究生，faculty=教师，staff=职工，other=其他，unknown=无法识别；缺失表示来源未提供。 */
  identityType?: "undergraduate" | "graduate" | "faculty" | "staff" | "other" | "unknown";
  /** 当前用户所属校区；缺失表示来源未提供。 */
  campus?: string;
  /** 个人资料在来源系统中的更新时间，格式为 RFC3339/UTC；缺失表示来源未提供。 */
  updatedAt?: string;
}
