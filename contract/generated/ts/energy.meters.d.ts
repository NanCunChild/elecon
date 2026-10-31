// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface EnergyMeters {
  /** 当前账户可查询的计量表；空数组表示已验证无表具。 */
  items: EnergyMetersItems[];
}

export interface EnergyMetersItems {
  /** 当前学校身份内的表标识。 */
  meterId: string;
  /** 表类型。 */
  type: "water" | "electricity" | "unknown";
  /** 计量单位，例如 kWh 或 m³。 */
  unit: string;
  /** 学校给出的表名；缺失不猜测。 */
  label?: string;
  /** 校区；学校未提供时省略。 */
  campus?: string;
  /** 宿舍楼；学校未提供时省略。 */
  dormitory?: string;
  /** 房间；学校未提供时省略。 */
  room?: string;
  /** 剩余量，与 unit 同单位；不是累计读数或金额，缺失时省略。 */
  remaining?: number;
  /** 学校最后抄表日，无时区日历日。 */
  lastReadDate?: string;
}
