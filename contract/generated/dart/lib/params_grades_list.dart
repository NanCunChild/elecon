// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class ParamsGradesList {
  const ParamsGradesList({
    this.term,
    this.filters,
  });

  /// 学期标识，如 2025-2026-2；省略 = 当前学期（ADR-001 §3.4 缺失语义）
  final String? term;
  /// query.controls 2.0同来源字段值，最多32项/32KiB UTF-8；仅同包声明新表单时使用。学校脚本重验字段和组合，不提升为其他宿主参数；省略保留旧标准参数行为。
  final Map<String, Object>? filters;
}
