// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface ParamsAccountSession {
  /** 包内账号声明的稳定 id。 */
  account: string;
  /** status 只读验证；login 用户明确触发且不自动重试。 */
  operation: "status" | "login";
}
