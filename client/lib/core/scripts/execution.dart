/// SDK19: data-only registrations and transactional, scope-local memory.
library;

import 'dart:convert';

import 'host_protocol.dart';

class ScriptHandlerRegistration {
  const ScriptHandlerRegistration(this.handler, this.stateKey);
  final String handler;
  final String stateKey;
}

class ScriptExecutionMemory {
  Map<String, String> values = {};
  Map<String, ScriptHandlerRegistration> registrations = {};

  void clear() {
    values.clear();
    registrations.clear();
  }
}

/// A turn is committed by its owner only after the complete session run succeeds.
/// No JS function or prior engine context crosses this boundary.
class ScriptExecutionTurn {
  ScriptExecutionTurn(
    ScriptExecutionMemory memory, {
    required this.trigger,
    this.handler,
    this.stateKey,
    this.deadline,
    int Function()? now,
  }) : values = Map.of(memory.values),
       registrations = Map.of(memory.registrations),
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final String trigger;
  final String? handler;
  final String? stateKey;
  final int? deadline;
  final int Function() _now;
  final Map<String, String> values;
  final Map<String, ScriptHandlerRegistration> registrations;
  final Map<String, int?> schedules = {};
  bool _finished = false;
  bool get missed => deadline != null && _now() > deadline!;
  static final _key = RegExp(r'^[a-zA-Z][a-zA-Z0-9_.-]{0,63}$');

  static String key(Object? value) {
    if (value is! String || !_key.hasMatch(value)) {
      throw const ScriptRunException('execution_invalid_request');
    }
    return value;
  }

  Object? call(String method, Object? raw) {
    if (_finished) throw const ScriptRunException('invocation_cancelled');
    if (raw is! Map<String, dynamic>) {
      throw const ScriptRunException('execution_invalid_request');
    }
    void fields(Set<String> names) {
      if (raw.length != names.length || !raw.keys.every(names.contains)) {
        throw const ScriptRunException('execution_invalid_request');
      }
    }

    switch (method) {
      case 'get':
        fields({'key'});
        final value = values[key(raw['key'])];
        if (value == null) {
          throw const ScriptRunException('execution_state_missing');
        }
        return jsonDecode(value);
      case 'set':
        fields({'key', 'value'});
        final name = key(raw['key']);
        _checkState(raw['value'], 0);
        final encoded = jsonEncode(raw['value']);
        final size = utf8.encode(encoded).length;
        if (size > 64 * 1024 ||
            (!values.containsKey(name) && values.length >= 32) ||
            values.entries
                    .where((e) => e.key != name)
                    .fold<int>(
                      size,
                      (n, e) => n + utf8.encode(e.value).length,
                    ) >
                256 * 1024) {
          throw const ScriptRunException('execution_state_limit');
        }
        values[name] = encoded;
        return null;
      case 'delete':
        fields({'key'});
        values.remove(key(raw['key']));
        return null;
      case 'register':
        fields({'id', 'handler', 'stateKey'});
        final id = key(raw['id']);
        final handler = key(raw['handler']);
        final stateKey = key(raw['stateKey']);
        if (!values.containsKey(stateKey)) {
          throw const ScriptRunException('execution_state_missing');
        }
        if (!registrations.containsKey(id) && registrations.length >= 16) {
          throw const ScriptRunException('execution_registration_limit');
        }
        registrations[id] = ScriptHandlerRegistration(handler, stateKey);
        schedules[id] = null;
        return null;
      case 'unregister':
        fields({'id'});
        final id = key(raw['id']);
        registrations.remove(id);
        schedules[id] = null;
        return null;
      case 'schedule':
        fields({'id', 'at'});
        final id = key(raw['id']);
        if (!registrations.containsKey(id)) {
          throw const ScriptRunException('execution_registration_missing');
        }
        final at = raw['at'];
        final now = _now();
        if (at is! int || at < now + 1000 || at > now + 86400000) {
          throw const ScriptRunException('execution_invalid_request');
        }
        schedules[id] = at;
        return null;
      case 'cancel':
        fields({'id'});
        schedules[key(raw['id'])] = null;
        return null;
      default:
        throw const ScriptRunException('execution_invalid_request');
    }
  }

  void commit(ScriptExecutionMemory memory) {
    if (_finished) throw StateError('execution turn already finished');
    _finished = true;
    memory.values = Map.of(values);
    memory.registrations = Map.of(registrations);
  }

  void discard() => _finished = true;

  static void _checkState(Object? value, int depth) {
    if (depth > 32) throw const ScriptRunException('execution_invalid_request');
    if (value == null ||
        value is String ||
        value is bool ||
        (value is num && value.isFinite)) {
      return;
    }
    if (value is List) {
      for (final item in value) {
        _checkState(item, depth + 1);
      }
      return;
    }
    if (value is Map<String, dynamic>) {
      for (final item in value.values) {
        _checkState(item, depth + 1);
      }
      return;
    }
    throw const ScriptRunException('execution_invalid_request');
  }
}
