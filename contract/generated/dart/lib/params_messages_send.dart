// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class ParamsMessagesSend {
  const ParamsMessagesSend({
    required this.accountId,
    required this.conversationId,
    required this.conversationKind,
    required this.clientId,
    required this.text,
  });

  /// 本次核验的远端服务账号 ID；须与请求账号一致。
  final String accountId;
  /// 源站会话 ID；由 serviceId/accountId/conversationKind 共同限定。
  final String conversationId;
  /// group 群聊，direct 私聊；相同 ID 的不同类型不合并。
  final String conversationKind;
  /// 调用方生成的非零十进制 uint64；同次点击保持不变，绝不自动重发。
  final String clientId;
  /// 用户明确发送的非空纯文本，最多 4000 字符；不可全为空白。
  final String text;
}
