// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class TermList {
  const TermList({
    this.currentTerm,
    this.items,
  });

  final String? currentTerm;
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

  final String id;
  final String name;
  final String? academicYear;
  final String? startDate;
  final String? endDate;
  final int? teachingWeeks;
}
