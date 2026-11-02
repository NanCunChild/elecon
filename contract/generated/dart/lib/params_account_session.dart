// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class ParamsAccountSession {
  const ParamsAccountSession({
    required this.account,
    required this.operation,
  });

  /// 包内账号声明的稳定 id。
  final String account;
  /// status 只读验证；login 用户明确触发且不自动重试。
  final String operation;
}
