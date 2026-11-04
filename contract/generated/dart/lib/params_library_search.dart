// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class ParamsLibrarySearch {
  const ParamsLibrarySearch({
    required this.query,
    this.page,
    this.size,
  });

  /// 书目关键词；去除首尾空白后非空。
  final String query;
  /// 页码，从1开始。
  final int? page;
  /// 每页书目数，1至50。
  final int? size;
}
