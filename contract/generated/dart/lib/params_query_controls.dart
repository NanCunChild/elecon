// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class ParamsQueryControls {
  const ParamsQueryControls({
    required this.target,
  });

  /// 要描述条件的同包只读查询，固定目标白名单。
  final String target;
}
