// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class EnergyUsage {
  const EnergyUsage({
    this.items,
  });

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

  final String? campus;
  final String? dormitory;
  final String? room;
  final String? type;
  final num? reading;
  final num? usage;
  final String? unit;
  final String? from;
  final String? to;
}
