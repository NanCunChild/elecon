/// One immutable request shared by every trusted-script trigger (ADR-081).
library;

import 'dart:convert';

class ScriptInvocation {
  ScriptInvocation({
    required this.packageId,
    required this.capability,
    Map<String, dynamic>? params,
    this.expectedDigest,
    this.interactive = true,
  }) : params = snapshotParams(params);

  final String packageId;
  final String capability;
  final Map<String, dynamic> params;
  final String? expectedDigest;
  final bool interactive;

  /// Capture before any await/queue so caller mutations cannot change execution,
  /// authentication decisions or the cache key. Invalid JSON never reaches JS.
  static Map<String, dynamic> snapshotParams(Map<String, dynamic>? value) {
    final encoded = jsonEncode(value ?? const <String, dynamic>{});
    if (utf8.encode(encoded).length > 1024 * 1024) {
      throw const FormatException('params_limit');
    }
    return _freeze(jsonDecode(encoded), 0) as Map<String, dynamic>;
  }

  static Object? _freeze(Object? value, int depth) {
    if (depth > 64) throw const FormatException('params_limit');
    if (value is Map<String, dynamic>) {
      return Map<String, dynamic>.unmodifiable(
        value.map((key, item) => MapEntry(key, _freeze(item, depth + 1))),
      );
    }
    if (value is List) {
      return List<Object?>.unmodifiable(
        value.map((item) => _freeze(item, depth + 1)),
      );
    }
    return value;
  }
}
