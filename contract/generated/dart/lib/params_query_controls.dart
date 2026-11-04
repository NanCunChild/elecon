// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class ParamsQueryControls {
  const ParamsQueryControls({
    required this.target,
    this.current,
    this.changed,
    this.load,
  });

  /// 要描述字段的同包只读查询目标。
  final String target;
  /// 当前字段草稿，最多32项/32KiB UTF-8；字段值不是宿主参数。省略表示读取初始表单，空值省略对应key。
  final Map<String, Object>? current;
  /// 本次改变的字段id，用于重新求取依赖选项；无用户字段变更时省略。
  final String? changed;
  /// 2.1：显式请求解析的1–32个唯一deferred字段id；省略表示基础表单。current仅含请求字段及其声明依赖的有效值。返回完整表单，宿主仅采用这些字段，不替换其他字段/标题/提交文案，不连锁加载或自动重试。
  final List<String>? load;
}
