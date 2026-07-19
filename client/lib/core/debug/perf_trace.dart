/// Compile-time performance tracing for development and profile builds.
///
/// Enable with `--dart-define=ELECON_PERF=true`. The default is false so the
/// trace calls are constant-folded away from normal builds.
library;

import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

const bool performanceTracingEnabled = bool.fromEnvironment(
  'ELECON_PERF',
  defaultValue: false,
);

class PerfTrace {
  PerfTrace._(this.name, this.attributes)
    : _startedAt = DateTime.now(),
      _stopwatch = Stopwatch()..start();

  factory PerfTrace.start(
    String name, {
    Map<String, Object?> attributes = const <String, Object?>{},
  }) {
    if (!performanceTracingEnabled) return _disabled;
    return PerfTrace._(name, Map<String, Object?>.unmodifiable(attributes));
  }

  static final PerfTrace _disabled = PerfTrace._disabledInstance();

  factory PerfTrace._disabledInstance() {
    final trace = PerfTrace._('disabled', const <String, Object?>{});
    trace._stopwatch.stop();
    return trace;
  }

  final String name;
  final Map<String, Object?> attributes;
  final DateTime _startedAt;
  final Stopwatch _stopwatch;
  final List<Map<String, Object?>> _events = <Map<String, Object?>>[];
  var _frameCount = 0;
  var _slowFrameCount = 0;
  var _maxFrameMs = 0.0;
  bool _observingFrames = false;
  bool _finished = false;

  static bool get enabled => performanceTracingEnabled;

  List<Map<String, Object?>> get events =>
      List<Map<String, Object?>>.unmodifiable(_events);

  void observeFrames() {
    if (!performanceTracingEnabled || _observingFrames) return;
    _observingFrames = true;
    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
  }

  void _onFrameTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      final frameMs = timing.totalSpan.inMicroseconds / 1000;
      _frameCount++;
      if (frameMs > 16.67) _slowFrameCount++;
      if (frameMs > _maxFrameMs) _maxFrameMs = frameMs;
    }
  }

  void mark(
    String label, {
    Map<String, Object?> data = const <String, Object?>{},
  }) {
    if (!performanceTracingEnabled || _finished) return;
    final event = <String, Object?>{
      'label': label,
      'ms': _stopwatch.elapsedMicroseconds / 1000,
      ...data,
    };
    _events.add(Map<String, Object?>.unmodifiable(event));
    developer.Timeline.instantSync(
      'elecon.perf.$name',
      arguments: <String, Object?>{'label': label, 'elapsed_ms': event['ms']},
    );
  }

  void finish({String? result}) {
    if (!performanceTracingEnabled || _finished) return;
    _finished = true;
    if (_observingFrames) {
      SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
      _observingFrames = false;
    }
    final output = <String, Object?>{
      'type': 'elecon.performance',
      'name': name,
      'started_at': _startedAt.toIso8601String(),
      'duration_ms': _stopwatch.elapsedMicroseconds / 1000,
      ...?result == null ? null : <String, Object?>{'result': result},
      ...attributes,
      'events': _events,
      'frames': <String, Object?>{
        'count': _frameCount,
        'slow_count': _slowFrameCount,
        'max_ms': _maxFrameMs,
      },
    };
    debugPrint('[perf] ${jsonEncode(output)}');
    _stopwatch.stop();
  }
}
