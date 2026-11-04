// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class QueryControls {
  const QueryControls({
    required this.target,
    required this.title,
    required this.submitLabel,
    required this.controls,
  });

  /// 这些控件绑定的同包只读领域查询；必须与请求target一致。
  final String target;
  /// 条件对话框的纯文本标题，脚本按当前语言返回。
  final String title;
  /// 显式应用条件并查询的按钮纯文本，不表示另一个能力或命令。
  final String submitLabel;
  /// 固定原生控件描述；id和绑定参数均唯一，组合由原生消费者再次校验。
  final List<QueryControlsControls> controls;
}

class QueryControlsControls {
  const QueryControlsControls({
    required this.id,
    required this.kind,
    required this.label,
    required this.parameter,
    this.initialValue,
    this.initialEnd,
    this.options,
  });

  /// 此组条件内稳定唯一的控件标识，不是可执行函数名。
  final String id;
  /// 固定原生输入种类，不接受脚本或HTML。
  final String kind;
  /// 输入标签纯文本，脚本按当前语言返回。
  final String label;
  /// 绑定已有标准参数；grades仅term；教室date/room；timeRange固定start并同时生成end。
  final String parameter;
  /// 可选默认值；省略表示沿当前参数或留空。timeRange格式HH:mm，必须与initialEnd同时给出。
  final String? initialValue;
  /// 仅timeRange可用的默认结束时刻HH:mm，与initialValue同日且更晚。
  final String? initialEnd;
  /// 仅select需要的唯一可选值列表，标签不是请求参数。
  final List<QueryControlsControlsOptions>? options;
}

class QueryControlsControlsOptions {
  const QueryControlsControlsOptions({
    required this.value,
    required this.label,
  });

  /// 送给领域参数的稳定字符串值。
  final String value;
  /// 供用户阅读的纯文本选项名称。
  final String label;
}
