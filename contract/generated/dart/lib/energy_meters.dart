// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class EnergyMeters {
  const EnergyMeters({
    required this.items,
  });

  /// 当前账户可查询的计量表；空数组表示已验证无表具。
  final List<EnergyMetersItems> items;
}

class EnergyMetersItems {
  const EnergyMetersItems({
    required this.meterId,
    required this.type,
    required this.unit,
    this.label,
    this.campus,
    this.dormitory,
    this.room,
    this.remaining,
    this.lastReadDate,
  });

  /// 当前学校身份内的表标识。
  final String meterId;
  /// 表类型。
  final String type;
  /// 计量单位，例如 kWh 或 m³。
  final String unit;
  /// 学校给出的表名；缺失不猜测。
  final String? label;
  /// 校区；学校未提供时省略。
  final String? campus;
  /// 宿舍楼；学校未提供时省略。
  final String? dormitory;
  /// 房间；学校未提供时省略。
  final String? room;
  /// 剩余量，与 unit 同单位；不是累计读数或金额，缺失时省略。
  final num? remaining;
  /// 学校最后抄表日，无时区日历日。
  final String? lastReadDate;
}
