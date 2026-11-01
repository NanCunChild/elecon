// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class ParamsFacultySearch {
  const ParamsFacultySearch({
    this.query,
    this.researchArea,
    this.page,
    this.pageSize,
  });

  /// 来源支持的教师姓名或关键词；不承诺精确匹配，须含非空白字符。与 researchArea 至少提供一项。
  final String? query;
  /// 研究方向关键词；须含非空白字符，与 query 同时存在时按来源的组合筛选语义查询。
  final String? researchArea;
  /// 从 1 开始的查询页码，缺失默认为 1。
  final int? page;
  /// 单页数量上限，单位为条，缺失默认为 10。
  final int? pageSize;
}
