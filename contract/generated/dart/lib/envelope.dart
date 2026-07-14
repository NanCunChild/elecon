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
  final EnvelopeSource source;
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

  final String schoolId;
  final String adapterId;
  final String adapterVersion;
  final String origin;
}

class EnvelopeFreshness {
  const EnvelopeFreshness({
    required this.fetchedAt,
    required this.ttlSeconds,
    required this.stale,
  });

  final String fetchedAt;
  final int ttlSeconds;
  final bool stale;
}
