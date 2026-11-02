// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class MessagesList {
  const MessagesList({
    required this.serviceId,
    required this.accountId,
    required this.accountLabel,
    required this.windowStartedAt,
    required this.fetchedAt,
    required this.coverage,
    required this.items,
  });

  /// 稳定服务标识；消息 ID 在服务及账号内唯一。
  final String serviceId;
  /// 本次核验的远端账号 ID。
  final String accountId;
  /// 本次核验的账号展示名。
  final String accountLabel;
  /// 本次前台读取窗口开始时刻，RFC3339。
  final String windowStartedAt;
  /// 本次读取完成时刻，RFC3339。
  final String fetchedAt;
  /// window 仅涵盖当前接收窗口；不是历史完整性、未读数或用户已读状态。
  final String coverage;
  /// 此窗口收到的群消息；无记录不代表无历史/未读消息。
  final List<MessagesListItems> items;
}

class MessagesListItems {
  const MessagesListItems({
    required this.id,
    required this.conversationId,
    this.senderId,
    required this.text,
    this.sentAt,
    this.activityId,
    required this.kind,
  });

  /// 源站稳定消息 ID，十进制大整数不得转浮点。
  final String id;
  /// 源站会话 ID；按服务/账号限定。
  final String conversationId;
  /// 可用时的源站发送人 ID，否则省略。
  final String? senderId;
  /// 纯文本消息摘要；不包含附件凭据或任意 HTML。
  final String text;
  /// 源站明确提供时的发送时刻，RFC3339；未知省略。
  final String? sentAt;
  /// 可用时的关联签到活动 ID；不能据此自动提交签到。
  final String? activityId;
  /// ADR-066：有限内容类型；activity/command只展示标识与纯文本摘要，不执行指令或活动。
  final String kind;
}
