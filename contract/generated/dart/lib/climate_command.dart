// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class ClimateCommand {
  const ClimateCommand({
    required this.status,
  });

  /// accepted 不等于 applied；只有独立状态核验才确认 applied。
  final String status;
}
