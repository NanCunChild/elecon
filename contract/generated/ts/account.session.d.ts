// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface AccountSession {
  /** authenticated 仅源站验证成功；signedOut 无凭据；expired 仅明确失效；网络错误/未验证为 unknown。 */
  status: "authenticated" | "signedOut" | "expired" | "unknown";
  /** 源站账号标识，可选，不能包含认证材料。 */
  accountId?: string;
  /** 账号显示名，可选纯文本。 */
  accountLabel?: string;
  /** 本次源站验证时刻；未完成验证时省略。 */
  checkedAt?: string;
}
