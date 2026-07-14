// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface Envelope {
  /** 数据域 schema id，如 elecon.grades.list */
  schema: string;
  /** schema 的 MAJOR.MINOR 版本 */
  schemaVersion: string;
  source: EnvelopeSource;
  freshness: EnvelopeFreshness;
  /** 域负载，结构由对应域 schema 定义 */
  data: unknown;
}

export interface EnvelopeSource {
  schoolId: string;
  adapterId: string;
  adapterVersion: string;
  origin: "client-direct" | "campus-relay" | "public-cache";
}

export interface EnvelopeFreshness {
  fetchedAt: string;
  ttlSeconds: number;
  stale: boolean;
}
