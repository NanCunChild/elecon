// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class ParamsScheduleWeek {
  const ParamsScheduleWeek({
    this.term,
    required this.week,
  });

  /// 学期标识，如 2025-2026-2；省略 = 当前学期
  final String? term;
  /// 教学周序号
  final int week;
}
