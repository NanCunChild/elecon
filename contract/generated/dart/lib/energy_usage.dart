// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class EnergyUsage {
  const EnergyUsage({
    this.items,
  });

  /// 水电用量记录列表；可选，缺失表示学校不提供。
  final List<EnergyUsageItems>? items;
}

class EnergyUsageItems {
  const EnergyUsageItems({
    this.campus,
    this.dormitory,
    this.room,
    this.type,
    this.reading,
    this.usage,
    this.unit,
    this.from,
    this.to,
  });

  /// 用量记录所属校区；可选，缺失表示学校不提供。
  final String? campus;
  /// 用量记录所属宿舍楼；可选，缺失表示学校不提供。
  final String? dormitory;
  /// 用量记录所属房间；可选，缺失表示学校不提供。
  final String? room;
  /// 能源类型：water=水，electricity=电，unknown=未知；可选，缺失表示学校不提供。
  final String? type;
  /// 计量表读数，单位由同级 unit 指定；可选，缺失表示学校不提供。
  final num? reading;
  /// 统计时段内的用量，单位由同级 unit 指定；可选，缺失表示学校不提供。
  final num? usage;
  /// 读数和用量的计量单位；可选，缺失表示学校不提供。
  final String? unit;
  /// 用量统计时段的起始时刻，RFC3339/UTC；可选，缺失表示学校不提供。
  final String? from;
  /// 用量统计时段的结束时刻，RFC3339/UTC；可选，缺失表示学校不提供。
  final String? to;
}
