// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface MessagesConversations {
  /** 稳定服务标识；不按显示名合并。 */
  serviceId: string;
  /** 本次核验的远端服务账号 ID；须与请求账号一致。 */
  accountId: string;
  /** 账号显示名；空表示未提供。 */
  accountLabel: string;
  /** 本次源站读取或发送核验完成的时刻，RFC3339；本地读取不更新。 */
  fetchedAt: string;
  /** complete 表示源站完整返回群与联系人目录；partial 表示部分目录失败或超出界限，不代表历史完整性。 */
  coverage: "complete" | "partial";
  /** 当前账号可访问的群与联系人；不包含未读推断。 */
  items: MessagesConversationsItems[];
}

export interface MessagesConversationsItems {
  /** 源站会话 ID；由 serviceId/accountId/conversationKind 共同限定。 */
  conversationId: string;
  /** group 群聊，direct 私聊；相同 ID 的不同类型不合并。 */
  conversationKind: "group" | "direct";
  /** 会话显示名；服务未提供时使用会话 ID。 */
  title: string;
}
