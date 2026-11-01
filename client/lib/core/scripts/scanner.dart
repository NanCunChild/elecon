/// ADR-045: transient QR text only; no navigation, storage or image data.
library;

import 'dart:convert';

class ScriptScannerException implements Exception {
  const ScriptScannerException(this.code);
  final String code;
}

/// The invocation supplies a live lease so a timed out run closes its camera.
typedef ScriptScanCall = Future<Object?> Function(bool Function() isActive);

Map<String, String>? validateScanResult(Object? raw) {
  if (raw == null) return null;
  if (raw is! Map ||
      raw.length != 2 ||
      raw['format'] != 'qrCode' ||
      raw['text'] is! String) {
    throw const ScriptScannerException('scanner_invalid_result');
  }
  final text = raw['text'] as String;
  if (text.isEmpty || text.length > 4096 || utf8.encode(text).length > 4096) {
    throw const ScriptScannerException('scanner_invalid_result');
  }
  return {'text': text, 'format': 'qrCode'};
}
