// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface ParamsMessagesEnrich {
  /** 本次核验的远端服务账号 ID；须与请求账号一致。 */
  accountId: string;
  /** 同一账号已展示的1–8个会话身份；kind与id共同标识实体，不允许重复。 */
  items: ParamsMessagesEnrichItems[];
}

export interface ParamsMessagesEnrichItems {
  /** 源站会话 ID；由 serviceId/accountId/conversationKind 共同限定。 */
  conversationId: string;
  /** group 群聊，direct 私聊；相同 ID 的不同类型不合并。 */
  conversationKind: "group" | "direct";
}
