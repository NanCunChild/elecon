/// ADR-099: process and rolling-source budgets cannot be reset by child calls.
library;

import 'host_protocol.dart';

class ScriptRequestBudget {
  ScriptRequestBudget({this.limit = 80});
  final int limit;
  int _used = 0;
  int get remaining => limit - _used;
  void consume() {
    if (remaining <= 0) throw const ScriptRunException('process_request_limit');
    _used++;
  }
}

class ScriptRequestWindow {
  ScriptRequestWindow({this.limit = 160, int Function()? now})
    : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);
  final int limit;
  final int Function() _now;
  final _requests = <int>[];
  int _pausedUntil = 0;
  void pause(Duration duration) {
    final until = _now() + duration.inMilliseconds;
    if (until > _pausedUntil) _pausedUntil = until;
  }

  int get remaining {
    if (_now() < _pausedUntil) return 0;
    _requests.removeWhere((t) => t <= _now() - 60000);
    return limit - _requests.length;
  }

  void consume() {
    if (remaining <= 0) throw const ScriptRunException('process_request_limit');
    _requests.add(_now());
  }
}
