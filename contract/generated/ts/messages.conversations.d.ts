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
  /** 已确认会话存在可展示的内容消息时为 true；仅明确核验为空时为 false；缺失表示未知，不能据此推断未读。 */
  hasContent?: boolean;
  /** 已确认内容消息中最新的源站发送时刻，RFC3339；未知省略，不用群资料更新时间或本地抓取时刻代替。 */
  lastMessageAt?: string;
  /** ADR-066：当前账号发送权限；allowed须来自当前源站核验，muted表示确认禁言/停用，unknown表示缺少证据。历史缓存不能授权发送。 */
  sendPermission?: "allowed" | "muted" | "unknown";
  /** 固定原因；不含源站异常或敏感信息。缺失时仅按sendPermission展示。 */
  sendPermissionReason?: "member_muted" | "group_muted" | "group_disabled" | "verification_failed";
  /** ADR-098：有序的0–4张PNG/JPEG缩略图data URI，每张解码最多16 KiB；缺失可保留已有头像，空数组明确清除。核心只消费字节，不发起图片网络请求。 */
  avatarImages?: string[];
}
