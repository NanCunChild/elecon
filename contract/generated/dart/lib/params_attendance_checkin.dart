// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class ParamsAttendanceCheckin {
  const ParamsAttendanceCheckin({
    this.location,
  });

  /// 本次用户明确选中的服务原生坐标；缺省不指定位置，不声称实测 GPS。
  final ParamsAttendanceCheckinLocation? location;
}

class ParamsAttendanceCheckinLocation {
  const ParamsAttendanceCheckinLocation({
    required this.latitude,
    required this.longitude,
    required this.address,
    required this.coordinateSystem,
  });

  /// 服务原生纬度，十进制度，有限数。
  final num latitude;
  /// 服务原生经度，十进制度，有限数。
  final num longitude;
  /// 本次所选地点地址，非空且最长 200 字。
  final String address;
  /// service 表示该来源服务所要求的原生坐标；从同一服务取得，不推断地图供应商或转换。
  final String coordinateSystem;
}
