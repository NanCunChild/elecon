// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class MessagesSend {
  const MessagesSend({
    required this.serviceId,
    required this.accountId,
    required this.accountLabel,
    required this.fetchedAt,
    required this.conversationId,
    required this.conversationKind,
    required this.clientId,
    required this.status,
    this.messageId,
    this.sentAt,
  });

  /// 稳定服务标识；不按显示名合并。
  final String serviceId;
  /// 本次核验的远端服务账号 ID；须与请求账号一致。
  final String accountId;
  /// 账号显示名；空表示未提供。
  final String accountLabel;
  /// 本次源站读取或发送核验完成的时刻，RFC3339；本地读取不更新。
  final String fetchedAt;
  /// 源站会话 ID；由 serviceId/accountId/conversationKind 共同限定。
  final String conversationId;
  /// group 群聊，direct 私聊；相同 ID 的不同类型不合并。
  final String conversationKind;
  /// 调用方生成的十进制 uint64 请求 ID；用于确认匹配，不承诺源站幂等。
  final String clientId;
  /// sent 已收到匹配服务器确认；rejected 明确拒绝；unknown 已尝试发送但不能确定结果。禁止自动重发。
  final String status;
  /// 仅 sent 提供服务器确认的消息 ID；不能用 clientId 冒充。
  final String? messageId;
  /// 服务器确认提供的发送时刻，RFC3339；未知省略。
  final String? sentAt;
}
