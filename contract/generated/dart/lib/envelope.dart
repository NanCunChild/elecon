// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class Envelope {
  const Envelope({
    required this.schema,
    required this.schemaVersion,
    required this.source,
    required this.freshness,
    required this.data,
  });

  /// 数据域 schema id，如 elecon.grades.list
  final String schema;
  /// schema 的 MAJOR.MINOR 版本
  final String schemaVersion;
  /// 数据来源元数据，包括学校、adapter 及数据来路。
  final EnvelopeSource source;
  /// 数据新鲜度元数据，与 adapter 代码版本无关。
  final EnvelopeFreshness freshness;
  /// 域负载，结构由对应域 schema 定义
  final Object? data;
}

class EnvelopeSource {
  const EnvelopeSource({
    required this.schoolId,
    required this.adapterId,
    required this.adapterVersion,
    required this.origin,
  });

  /// 数据所属学校的标识。
  final String schoolId;
  /// 产出数据的 adapter 标识。
  final String adapterId;
  /// 产出数据的 adapter 代码版本。
  final String adapterVersion;
  /// 数据来路：客户端直连、校内授权中继或公网公开数据缓存。
  final String origin;
}

class EnvelopeFreshness {
  const EnvelopeFreshness({
    required this.fetchedAt,
    required this.ttlSeconds,
    required this.stale,
  });

  /// 数据获取时刻，RFC3339/UTC。
  final String fetchedAt;
  /// 数据有效期，单位为秒。
  final int ttlSeconds;
  /// 数据当前是否已过有效期。
  final bool stale;
}
