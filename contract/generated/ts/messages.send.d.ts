// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface MessagesSend {
  /** 稳定服务标识；不按显示名合并。 */
  serviceId: string;
  /** 本次核验的远端服务账号 ID；须与请求账号一致。 */
  accountId: string;
  /** 账号显示名；空表示未提供。 */
  accountLabel: string;
  /** 本次源站读取或发送核验完成的时刻，RFC3339；本地读取不更新。 */
  fetchedAt: string;
  /** 源站会话 ID；由 serviceId/accountId/conversationKind 共同限定。 */
  conversationId: string;
  /** group 群聊，direct 私聊；相同 ID 的不同类型不合并。 */
  conversationKind: "group" | "direct";
  /** 调用方生成的十进制 uint64 请求 ID；用于确认匹配，不承诺源站幂等。 */
  clientId: string;
  /** sent 已收到匹配服务器确认；rejected 明确拒绝；unknown 已尝试发送但不能确定结果。禁止自动重发。 */
  status: "sent" | "rejected" | "unknown";
  /** 仅 sent 提供服务器确认的消息 ID；不能用 clientId 冒充。 */
  messageId?: string;
  /** 服务器确认提供的发送时刻，RFC3339；未知省略。 */
  sentAt?: string;
}
