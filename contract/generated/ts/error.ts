// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface Error {
  schema: unknown;
  schemaVersion: string;
  error: ErrorError;
}

export interface ErrorError {
  kind: "auth_required" | "source_unavailable" | "network_blocked" | "rate_limited" | "parse_failed" | "capability_unsupported";
  retriable: boolean;
  capability: string;
  message: string;
}
