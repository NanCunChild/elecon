// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class ParamsCardTransactions {
  const ParamsCardTransactions({
    this.from,
    this.to,
    this.page,
    this.size,
  });

  /// 起始日期（含）；省略 = 接口默认窗口
  final String? from;
  /// 结束日期（含）；省略 = 至今
  final String? to;
  /// 页码，从 1 起
  final int? page;
  /// 每页条数
  final int? size;
}
