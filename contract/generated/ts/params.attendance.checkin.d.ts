// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface ParamsAttendanceCheckin {
  /** 本次用户明确选中的服务原生坐标；缺省不指定位置，不声称实测 GPS。 */
  location?: ParamsAttendanceCheckinLocation;
}

export interface ParamsAttendanceCheckinLocation {
  /** 服务原生纬度，十进制度，有限数。 */
  latitude: number;
  /** 服务原生经度，十进制度，有限数。 */
  longitude: number;
  /** 本次所选地点地址，非空且最长 200 字。 */
  address: string;
  /** service 表示该来源服务所要求的原生坐标；从同一服务取得，不推断地图供应商或转换。 */
  coordinateSystem: string;
}
