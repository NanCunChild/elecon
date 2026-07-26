// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface Envelope {
  /** 数据域 schema id，如 elecon.grades.list */
  schema: string;
  /** schema 的 MAJOR.MINOR 版本 */
  schemaVersion: string;
  /** 数据来源元数据，包括学校、adapter 及数据来路。 */
  source: EnvelopeSource;
  /** 数据新鲜度元数据，与 adapter 代码版本无关。 */
  freshness: EnvelopeFreshness;
  /** 域负载，结构由对应域 schema 定义 */
  data: unknown;
}

export interface EnvelopeSource {
  /** 数据所属学校的标识。 */
  schoolId: string;
  /** 产出数据的 adapter 标识。 */
  adapterId: string;
  /** 产出数据的 adapter 代码版本。 */
  adapterVersion: string;
  /** 数据来路：客户端直连、校内授权中继或公网公开数据缓存。 */
  origin: "client-direct" | "campus-relay" | "public-cache";
}

export interface EnvelopeFreshness {
  /** 数据获取时刻，RFC3339/UTC。 */
  fetchedAt: string;
  /** 数据有效期，单位为秒。 */
  ttlSeconds: number;
  /** 数据当前是否已过有效期。 */
  stale: boolean;
}
