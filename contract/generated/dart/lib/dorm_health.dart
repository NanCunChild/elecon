// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class DormHealth {
  const DormHealth({
    this.items,
  });

  final List<DormHealthItems>? items;
}

class DormHealthItems {
  const DormHealthItems({
    this.metric,
    this.value,
    this.unit,
    this.measuredAt,
    this.status,
  });

  final String? metric;
  final num? value;
  final String? unit;
  final String? measuredAt;
  final String? status;
}
