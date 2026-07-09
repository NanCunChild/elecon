// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class ParamsNoticeList {
  const ParamsNoticeList({
    this.category,
    this.page,
    this.size,
  });

  /// 按分类过滤；省略 = 全部（与 elecon.notice.list.category 对齐）
  final String? category;
  /// 页码，从 1 起
  final int? page;
  /// 每页条数
  final int? size;
}
