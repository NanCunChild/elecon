/// ADR-099: bounded host work; conflicting credential sets run in FIFO order.
library;

import 'dart:async';
import 'host_protocol.dart';

class ScriptWorkScheduler {
  ScriptWorkScheduler({
    this.limit = 3,
    this.backgroundLimit = 1,
    this.groupLimit,
  });
  static final engines = ScriptWorkScheduler();
  static final http = ScriptWorkScheduler(
    limit: 8,
    backgroundLimit: 8,
    groupLimit: 2,
  );
  final int limit, backgroundLimit;
  final int? groupLimit;
  final _waiting = <_Work>[];
  final _running = <_Work>[];
  int _sequence = 0;

  Future<T> run<T>({
    required Future<T> Function() action,
    required Object owner,
    Set<String>? keys,
    bool background = false,
    String? group,
    bool Function()? isActive,
    Future<void>? cancelled,
    Object? tag,
  }) {
    if (_waiting.length >= 64) {
      return Future.error(const ScriptRunException('scheduler_queue_limit'));
    }
    final result = Completer<T>();
    final work = _Work(
      owner,
      tag,
      keys == null ? null : Set.unmodifiable(keys),
      background,
      group,
      _sequence++,
      isActive ?? () => true,
      () async {
        result.complete(await action());
      },
      (Object error, StackTrace stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    _waiting.add(work);
    cancelled?.then((_) {
      if (_waiting.remove(work)) {
        work.fail(
          const ScriptRunException('script_cancelled'),
          StackTrace.current,
        );
        _drain();
      }
    });
    _drain();
    return result.future;
  }

  void recheck() => _drain();
  void promote(Object tag) {
    for (final work in _waiting) {
      if (identical(work.tag, tag)) work.background = false;
    }
    _drain();
  }

  bool _conflicts(_Work a, _Work b) =>
      identical(a.owner, b.owner) &&
      (a.keys == null || b.keys == null || a.keys!.any(b.keys!.contains));

  void _drain() {
    for (final work in _waiting.toList()) {
      if (!work.active()) {
        _waiting.remove(work);
        work.fail(
          const ScriptRunException('script_cancelled'),
          StackTrace.current,
        );
      }
    }
    while (_running.length < limit) {
      final candidates = _waiting.toList()
        ..sort((a, b) {
          final priority = (a.background ? 1 : 0).compareTo(
            b.background ? 1 : 0,
          );
          return priority == 0 ? a.sequence.compareTo(b.sequence) : priority;
        });
      _Work? next;
      for (final work in candidates) {
        if (work.background &&
            _running.where((w) => w.background).length >= backgroundLimit) {
          continue;
        }
        if (groupLimit != null &&
            _running.where((w) => w.group == work.group).length >=
                groupLimit!) {
          continue;
        }
        if (_running.any((w) => _conflicts(w, work))) continue;
        if (_waiting.any(
          (w) => w.sequence < work.sequence && _conflicts(w, work),
        )) {
          continue;
        }
        next = work;
        break;
      }
      if (next == null) return;
      final work = next;
      _waiting.remove(work);
      _running.add(work);
      work.zone
          .run(() => Future<void>.sync(work.action))
          .catchError((Object e, StackTrace s) {
            work.fail(e, s);
          })
          .whenComplete(() {
            _running.remove(work);
            _drain();
          });
    }
  }

  /// A permit holds one slot until released, including response body reads.
  Future<void Function()> acquire({
    required Object owner,
    required String group,
    required bool Function() isActive,
    required Future<void> cancelled,
  }) {
    final acquired = Completer<void Function()>();
    final released = Completer<void>();
    run<void>(
      owner: owner,
      keys: {},
      group: group,
      isActive: isActive,
      cancelled: cancelled,
      action: () async {
        if (!isActive()) throw const ScriptRunException('script_cancelled');
        acquired.complete(() {
          if (!released.isCompleted) released.complete();
        });
        await released.future;
      },
    ).catchError((Object e, StackTrace s) {
      if (!acquired.isCompleted) acquired.completeError(e, s);
    });
    return acquired.future;
  }
}

class _Work {
  _Work(
    this.owner,
    this.tag,
    this.keys,
    this.background,
    this.group,
    this.sequence,
    this.active,
    this.action,
    this.fail,
  );
  final Zone zone = Zone.current;
  final Object owner;
  final Object? tag;
  final Set<String>? keys;
  bool background;
  final String? group;
  final int sequence;
  final bool Function() active;
  final Future<void> Function() action;
  final void Function(Object, StackTrace) fail;
}
