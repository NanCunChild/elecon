// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class MessagesConversations {
  const MessagesConversations({
    required this.serviceId,
    required this.accountId,
    required this.accountLabel,
    required this.fetchedAt,
    required this.coverage,
    required this.items,
  });

  /// 稳定服务标识；不按显示名合并。
  final String serviceId;
  /// 本次核验的远端服务账号 ID；须与请求账号一致。
  final String accountId;
  /// 账号显示名；空表示未提供。
  final String accountLabel;
  /// 本次源站读取或发送核验完成的时刻，RFC3339；本地读取不更新。
  final String fetchedAt;
  /// complete 表示源站完整返回群与联系人目录；partial 表示部分目录失败或超出界限，不代表历史完整性。
  final String coverage;
  /// 当前账号可访问的群与联系人；不包含未读推断。
  final List<MessagesConversationsItems> items;
}

class MessagesConversationsItems {
  const MessagesConversationsItems({
    required this.conversationId,
    required this.conversationKind,
    required this.title,
  });

  /// 源站会话 ID；由 serviceId/accountId/conversationKind 共同限定。
  final String conversationId;
  /// group 群聊，direct 私聊；相同 ID 的不同类型不合并。
  final String conversationKind;
  /// 会话显示名；服务未提供时使用会话 ID。
  final String title;
}
