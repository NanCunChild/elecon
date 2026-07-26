// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class Error {
  const Error({
    required this.schema,
    required this.schemaVersion,
    required this.error,
  });

  /// 错误契约的固定 schema id，恒为 elecon.error。
  final Object? schema;
  /// 错误 schema 的 MAJOR.MINOR 版本。
  final String schemaVersion;
  /// 归一化错误详情，供 UI 和同步层决定重试、登录或降级。
  final ErrorError error;
}

class ErrorError {
  const ErrorError({
    required this.kind,
    required this.retriable,
    required this.capability,
    required this.message,
  });

  /// 错误类别：需认证、源站不可用、网络白名单拦截、限流、解析失败或能力不支持。
  final String kind;
  /// 当前错误是否适合重试。
  final bool retriable;
  /// 发生错误的 capability id。
  final String capability;
  /// 可安全展示的错误文案，最长 256 字符；禁止包含凭证、堆栈、内网地址等敏感信息（ADR-001 §7）。
  final String message;
}
