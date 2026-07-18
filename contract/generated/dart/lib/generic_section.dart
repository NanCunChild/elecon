// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class GenericSection {
  const GenericSection({
    required this.sectionId,
    required this.title,
    this.fields,
    this.table,
  });

  /// 本节稳定标识（校内作用域字符串）
  final String sectionId;
  /// 本节标题，纯文本，无样式
  final String title;
  /// 带标签字段 / 键值组
  final List<GenericSectionFields>? fields;
  /// 简单表格（可选）
  final GenericSectionTable? table;
}

class GenericSectionFields {
  const GenericSectionFields({
    required this.label,
    required this.role,
    required this.value,
  });

  /// 字段标签，纯文本
  final String label;
  final String role;
  final Object value;
}

class GenericSectionTable {
  const GenericSectionTable({
    required this.columns,
    required this.rows,
  });

  final List<GenericSectionTableColumns> columns;
  final List<List<Object>> rows;
}

class GenericSectionTableColumns {
  const GenericSectionTableColumns({
    required this.label,
    required this.role,
  });

  final String label;
  final String role;
}
