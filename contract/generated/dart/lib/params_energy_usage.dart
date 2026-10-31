// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class ParamsEnergyUsage {
  const ParamsEnergyUsage({
    this.meterId,
    this.from,
    this.to,
  });

  /// 指定当前账户发现的表；多表提供者要求选择。
  final String? meterId;
  /// 查询起始时刻，RFC3339/UTC；缺失采用学校默认窗口。
  final String? from;
  /// 查询结束时刻，RFC3339/UTC；缺失采用学校默认窗口。
  final String? to;
}
