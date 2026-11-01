// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface MessagesList {
  /** 稳定服务标识；消息 ID 在服务及账号内唯一。 */
  serviceId: string;
  /** 本次核验的远端账号 ID。 */
  accountId: string;
  /** 本次核验的账号展示名。 */
  accountLabel: string;
  /** 本次前台读取窗口开始时刻，RFC3339。 */
  windowStartedAt: string;
  /** 本次读取完成时刻，RFC3339。 */
  fetchedAt: string;
  /** window 仅涵盖当前接收窗口；不是历史完整性、未读数或用户已读状态。 */
  coverage: "window";
  /** 此窗口收到的群消息；无记录不代表无历史/未读消息。 */
  items: MessagesListItems[];
}

export interface MessagesListItems {
  /** 源站稳定消息 ID，十进制大整数不得转浮点。 */
  id: string;
  /** 源站会话 ID；按服务/账号限定。 */
  conversationId: string;
  /** 可用时的源站发送人 ID，否则省略。 */
  senderId?: string;
  /** 纯文本消息摘要；不包含附件凭据或任意 HTML。 */
  text: string;
  /** 源站明确提供时的发送时刻，RFC3339；未知省略。 */
  sentAt?: string;
  /** 可用时的关联签到活动 ID；不能据此自动提交签到。 */
  activityId?: string;
}
