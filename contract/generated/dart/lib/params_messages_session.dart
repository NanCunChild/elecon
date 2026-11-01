// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class ParamsMessagesSession {
  const ParamsMessagesSession({
    this.operation,
  });

  /// 默认 status，仅查询；login 为显式登录；logout 仅清除此服务本地会话，不等于远端注销。
  final String? operation;
}
