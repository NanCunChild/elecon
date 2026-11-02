/// ADR-058: finite foreground inputs; no file paths or device identifiers.
library;

import 'dart:async';
import 'dart:convert';

const maxScriptImageBytes = 512 * 1024;
const scriptDeviceInputKinds = {'camera', 'image', 'location'};
typedef ScriptDeviceInputCall =
    Future<Object?> Function(String kind, bool Function() isActive);

class ScriptDeviceInputException implements Exception {
  const ScriptDeviceInputException(this.code);
  final String code;
}

/// Only the host may hold this lease while its OS image picker is visible.
/// It does not survive identity cancellation and expires using wall time even
/// when the platform suspends Dart timers. No script work resumes in background.
class ScriptSystemInputLease {
  Object? _owner;
  bool foreground = true;
  bool get executionAllowed => foreground || active;
  DateTime? _deadline;
  bool get active => _owner != null && DateTime.now().isBefore(_deadline!);
  void revoke() {
    _owner = null;
    _deadline = null;
  }

  Future<T> run<T>(Future<T> Function() operation) async {
    if (active) throw const ScriptDeviceInputException('device_input_busy');
    final owner = Object();
    _owner = owner;
    _deadline = DateTime.now().add(const Duration(seconds: 90));
    try {
      final result = await operation().timeout(const Duration(seconds: 90));
      if (!identical(owner, _owner) || !active) {
        throw const ScriptDeviceInputException('invocation_cancelled');
      }
      return result;
    } on TimeoutException {
      throw const ScriptDeviceInputException('device_input_timeout');
    } finally {
      if (identical(owner, _owner)) revoke();
    }
  }
}

Map<String, Object?>? validateDeviceInput(String kind, Object? raw) {
  if (!scriptDeviceInputKinds.contains(kind)) {
    throw const ScriptDeviceInputException('device_input_invalid_request');
  }
  if (raw == null) return null;
  if (raw is! Map) {
    throw const ScriptDeviceInputException('device_input_invalid_result');
  }
  bool exact(Set<String> keys) =>
      raw.keys.toSet().containsAll(keys) && raw.length == keys.length;
  if (kind == 'location') {
    if (!exact({
          'latitude',
          'longitude',
          'accuracyMeters',
          'capturedAt',
          'coordinateSystem',
        }) ||
        raw['coordinateSystem'] != 'wgs84' ||
        raw['latitude'] is! num ||
        !(raw['latitude'] as num).isFinite ||
        (raw['latitude'] as num).abs() > 90 ||
        raw['longitude'] is! num ||
        !(raw['longitude'] as num).isFinite ||
        (raw['longitude'] as num).abs() > 180 ||
        raw['accuracyMeters'] is! num ||
        !(raw['accuracyMeters'] as num).isFinite ||
        (raw['accuracyMeters'] as num) < 0 ||
        raw['capturedAt'] is! String ||
        !RegExp(
          r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$',
        ).hasMatch(raw['capturedAt'] as String) ||
        DateTime.tryParse(raw['capturedAt'] as String)?.isUtc != true) {
      throw const ScriptDeviceInputException('device_input_invalid_result');
    }
    return Map<String, Object?>.from(raw);
  }
  final bytes = raw['bytes'];
  if (!exact({'bytes', 'mimeType', 'width', 'height'}) ||
      raw['mimeType'] != 'image/png' ||
      bytes is! List ||
      bytes.length < 8 ||
      bytes.length > maxScriptImageBytes ||
      bytes.any((b) => b is! int || b < 0 || b > 255) ||
      jsonEncode(bytes.take(8).toList()) != '[137,80,78,71,13,10,26,10]' ||
      raw['width'] is! int ||
      (raw['width'] as int) < 1 ||
      (raw['width'] as int) > 1280 ||
      raw['height'] is! int ||
      (raw['height'] as int) < 1 ||
      (raw['height'] as int) > 1280) {
    throw const ScriptDeviceInputException('device_input_invalid_result');
  }
  return {
    'bytes': List<int>.from(bytes),
    'mimeType': 'image/png',
    'width': raw['width'],
    'height': raw['height'],
  };
}
