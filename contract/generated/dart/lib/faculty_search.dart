// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class FacultySearch {
  const FacultySearch({
    required this.items,
    required this.page,
    required this.pageSize,
    required this.hasMore,
    required this.sourceSystem,
    required this.sourceUrl,
    this.total,
  });

  /// 当前查询页的教师；空数组表示本页无匹配结果，不能用于表示查询失败。
  final List<FacultySearchItems> items;
  /// 本页对应的请求页码，从 1 开始。
  final int page;
  /// 本次请求每页教师数量上限，单位为条；实际 items 可少于此值。
  final int pageSize;
  /// 来源是否确认当前查询还有下一页；false 表示没有下一页。
  final bool hasMore;
  /// 校内来源系统的稳定标识，与学校共同限定教师 id。
  final String sourceSystem;
  /// 查询来源的公开 HTTPS 页面，供核对数据来源。
  final String sourceUrl;
  /// 来源报告的本次筛选结果总条数；缺失表示来源未提供，不从当前页推测。
  final int? total;
}

class FacultySearchItems {
  const FacultySearchItems({
    required this.id,
    required this.name,
    this.department,
    this.title,
    this.disciplines,
    this.researchAreas,
    this.summary,
    this.profileUrl,
  });

  /// 学校和 sourceSystem 作用域内稳定的教师标识；同名教师不得合并。
  final String id;
  /// 教师公开显示姓名，纯文本。
  final String name;
  /// 公开所属学院或单位，纯文本；缺失表示来源未提供。
  final String? department;
  /// 公开职称，纯文本；缺失表示来源未提供。
  final String? title;
  /// 公开学科名称，纯文本；缺失表示来源未提供。
  final List<String>? disciplines;
  /// 公开研究方向，纯文本；缺失表示来源未提供。
  final List<String>? researchAreas;
  /// 公开简介摘录，纯文本，可能有截断；缺失表示来源未提供。
  final String? summary;
  /// 教师公开主页的绝对 HTTPS URL；缺失表示来源未提供，不作为教师身份。
  final String? profileUrl;
}
