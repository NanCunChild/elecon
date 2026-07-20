/// Adapter loading diagnostics. These messages are for debugging only and
/// never influence the fail-closed loading decision.
library;

enum AdapterDiagnosticKind {
  network,
  timeout,
  httpStatus,
  invalidUrl,
  sizeLimit,
  decompression,
  parse,
  storage,
  signature,
  contentAddress,
  missingSource,
  revoked,
  policy,
}

class AdapterDiagnostic {
  const AdapterDiagnostic({
    required this.kind,
    required this.stage,
    required this.message,
    this.uri,
    this.statusCode,
  });

  final AdapterDiagnosticKind kind;
  final String stage;
  final String message;
  final Uri? uri;
  final int? statusCode;

  String get summary {
    final status = statusCode == null ? '' : ' HTTP $statusCode';
    final target = uri == null ? '' : ' (${uri!.host}${uri!.path})';
    return '[$stage/${kind.name}$status]$target $message';
  }
}
