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
  /// 字段的语义角色提示；本体据此决定渲染。
  final String role;
  /// 字段的归一化原始值；格式由 role 约定。
  final Object value;
}

class GenericSectionTable {
  const GenericSectionTable({
    required this.columns,
    required this.rows,
  });

  /// 表格列定义，顺序与每行的数据值一致。
  final List<GenericSectionTableColumns> columns;
  /// 表格数据行；每行各值按 columns 的顺序排列。
  final List<List<Object>> rows;
}

class GenericSectionTableColumns {
  const GenericSectionTableColumns({
    required this.label,
    required this.role,
  });

  /// 表格列标题，纯文本。
  final String label;
  /// 该列的语义角色提示；本体据此决定渲染。
  final String role;
}
