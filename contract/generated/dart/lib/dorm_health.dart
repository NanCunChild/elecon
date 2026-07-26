// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class DormHealth {
  const DormHealth({
    this.items,
  });

  /// 宿舍健康指标列表；可选，缺失表示学校不提供。
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

  /// 健康指标名称；可选，缺失表示学校不提供。
  final String? metric;
  /// 指标测量值，单位由同级 unit 指定；可选，缺失表示学校不提供。
  final num? value;
  /// 指标测量值的单位；可选，缺失表示学校不提供。
  final String? unit;
  /// 指标测量时刻，RFC3339/UTC；可选，缺失表示学校不提供。
  final String? measuredAt;
  /// 指标状态：normal=正常，abnormal=异常，unknown=未知；可选，缺失表示学校不提供。
  final String? status;
}
