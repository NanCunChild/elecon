/// ADR-100: private, sanitized, bounded and independent of business success.
library;

import 'dart:convert';
import 'dart:io';
import 'dev_log.dart';

class DevLogFile {
  DevLogFile(
    this.directory, {
    this.maxBytes = 4 * 1024 * 1024,
    this.maxPendingBytes = 2 * 1024 * 1024,
  });

  final Directory directory;
  final int maxBytes;
  final int maxPendingBytes;
  Future<void> _writes = Future.value();
  int _pendingBytes = 0;
  int dropped = 0;
  int failures = 0;
  int? _size;

  File _file([int index = 0]) =>
      File('${directory.path}/dev-log.jsonl${index == 0 ? '' : '.$index'}');

  void add(DevLogEntry entry) {
    // Entries have already passed DevLog's category gates and sanitization.
    final line = jsonEncode({
      'time': entry.time.toUtc().toIso8601String(),
      'category': entry.category.name,
      'message': entry.message,
      if (entry.ok != null) 'ok': entry.ok,
      if (entry.statusCode != null) 'statusCode': entry.statusCode,
      'dropped': dropped,
      'writeFailures': failures,
    });
    final bytes = utf8.encode('$line\n');
    if (_pendingBytes + bytes.length > maxPendingBytes) {
      dropped++;
      return;
    }
    _pendingBytes += bytes.length;
    _writes = _writes.then((_) async {
      try {
        await directory.create(recursive: true);
        _size ??= await _file().exists() ? await _file().length() : 0;
        if (_size! > 0 && _size! + bytes.length > maxBytes) {
          if (await _file(3).exists()) await _file(3).delete();
          for (var index = 2; index >= 0; index--) {
            if (await _file(index).exists()) {
              await _file(index).rename(_file(index + 1).path);
            }
          }
          _size = 0;
        }
        await _file().writeAsBytes(bytes, mode: FileMode.append, flush: true);
        _size = _size! + bytes.length;
      } catch (_) {
        // No raw filesystem exception (which may contain private paths).
        failures++;
        _size = null;
      } finally {
        _pendingBytes -= bytes.length;
      }
    });
  }

  Future<void> flush() => _writes;
}
