import 'dart:convert';
import 'dart:io';
import 'package:elecon/core/debug/dev_log.dart';
import 'package:elecon/core/debug/dev_log_file.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('elecon-debug-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test(
    'file sink retains full sanitized messages beyond UI capacity and restarts',
    () async {
      final files = DevLogFile(root);
      final log = DevLog(capacity: 1);
      log.runtime('startup');
      log.attachSink(files.add);
      final long = 'x' * 12000;
      log.adapter(
        'info',
        '$long password=synthetic-secret https://example.edu/p?q=secret',
      );
      log.runtime('finished');
      await files.flush();
      expect(log.entries, hasLength(1));
      final raw = await File('${root.path}/dev-log.jsonl').readAsString();
      expect(raw, isNot(contains('synthetic-secret')));
      expect(raw, isNot(contains('?q=')));
      final entries = const LineSplitter()
          .convert(raw)
          .map(jsonDecode)
          .toList();
      expect(entries, hasLength(3));
      expect(entries[1]['message'], contains(long));
      final restarted = DevLogFile(root);
      log.attachSink(restarted.add);
      await restarted.flush();
      expect(
        const LineSplitter().convert(
          await File('${root.path}/dev-log.jsonl').readAsString(),
        ),
        hasLength(4),
      );
    },
  );

  test(
    'rotation keeps four whole records and failures do not fail callers',
    () async {
      final files = DevLogFile(root, maxBytes: 100);
      final log = DevLog()..attachSink(files.add);
      for (var i = 0; i < 7; i++) {
        log.runtime('record $i');
      }
      await files.flush();
      final records = <dynamic>[];
      for (final index in [3, 2, 1, 0]) {
        final file = File(
          '${root.path}/dev-log.jsonl${index == 0 ? '' : '.$index'}',
        );
        records.addAll(
          const LineSplitter()
              .convert(await file.readAsString())
              .map(jsonDecode),
        );
      }
      expect(records.map((r) => r['message']), [
        'record 3',
        'record 4',
        'record 5',
        'record 6',
      ]);
      final bad = DevLogFile(Directory('${root.path}/dev-log.jsonl'));
      log.attachSink(bad.add);
      await bad.flush();
      expect(bad.failures, greaterThan(0));
      final limited = DevLogFile(root, maxPendingBytes: 1);
      log.attachSink(limited.add);
      expect(limited.dropped, greaterThan(0));
    },
  );
}
