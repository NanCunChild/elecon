// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class TermList {
  const TermList({
    this.currentTerm,
    this.items,
  });

  /// 当前学期标识；缺失表示来源未提供或无法确定。
  final String? currentTerm;
  /// 学期条目列表；缺失表示来源未提供学期列表。
  final List<TermListItems>? items;
}

class TermListItems {
  const TermListItems({
    required this.id,
    required this.name,
    this.academicYear,
    this.startDate,
    this.endDate,
    this.teachingWeeks,
  });

  /// 学期在校内系统中的标识。
  final String id;
  /// 学期展示名称。
  final String name;
  /// 学期所属学年；缺失表示来源未提供。
  final String? academicYear;
  /// 学期开始日，格式为 YYYY-MM-DD；缺失表示来源未提供。
  final String? startDate;
  /// 学期结束日，格式为 YYYY-MM-DD；缺失表示来源未提供。
  final String? endDate;
  /// 学期教学周总数，单位为周；缺失表示来源未提供。
  final int? teachingWeeks;
}
