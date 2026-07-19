import 'package:elecon/core/debug/perf_trace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('performance tracing follows the compile-time flag', () {
    final trace = PerfTrace.start('test', attributes: const {'fixture': true});
    trace.mark('before');
    trace.finish(result: 'ok');

    if (PerfTrace.enabled) {
      expect(trace.events, hasLength(1));
      expect(trace.events.single['label'], 'before');
    } else {
      expect(trace.events, isEmpty);
    }
  });
}
