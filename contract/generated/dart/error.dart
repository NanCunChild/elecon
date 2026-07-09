// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class Error {
  const Error({
    required this.schema,
    required this.schemaVersion,
    required this.error,
  });

  final Object? schema;
  final String schemaVersion;
  final ErrorError error;
}

class ErrorError {
  const ErrorError({
    required this.kind,
    required this.retriable,
    required this.capability,
    required this.message,
  });

  final String kind;
  final bool retriable;
  final String capability;
  final String message;
}
