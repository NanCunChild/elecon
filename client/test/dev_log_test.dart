/// DevLog 脱敏与可见性策略。
library;

import 'package:elecon/core/debug/dev_log.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sanitizeUrlForLog', () {
    test('剥离 query / fragment / userInfo', () {
      expect(
        sanitizeUrlForLog(
          'https://user:pass@ids.example.edu/auth?ticket=SECRET#frag',
        ),
        'https://ids.example.edu/auth',
      );
    });

    test('保留非默认 port 与 path', () {
      expect(
        sanitizeUrlForLog('http://127.0.0.1:8080/echo?x=1'),
        'http://127.0.0.1:8080/echo',
      );
    });

    test('非法 URL', () {
      expect(sanitizeUrlForLog('not a url'), '<invalid-url>');
    });
  });

  group('DevLog', () {
    late DevLog log;

    setUp(() {
      log = DevLog(capacity: 3);
    });

    test('network 写入无参 URL + 状态', () {
      log.network(
        method: 'get',
        url: 'https://ehall.example.edu/api?token=x',
        statusCode: 200,
        ok: true,
      );
      expect(log.entries, hasLength(1));
      expect(log.entries.first.message, 'GET https://ehall.example.edu/api → 200');
      expect(log.entries.first.category, DevLogCategory.network);
      expect(log.entries.first.ok, isTrue);
    });

    test('runtime 仅 debug 写入', () {
      log.runtime('H 档就绪');
      if (kDebugMode) {
        expect(log.entries, hasLength(1));
        expect(log.entries.first.category, DevLogCategory.runtime);
      } else {
        expect(log.entries, isEmpty);
      }
    });

    test('visible：非 debug 仅 network', () {
      log.network(method: 'GET', url: 'https://a.example/', statusCode: 204);
      log.runtime('secret-meta');
      final v = log.visible();
      for (final e in v) {
        if (!kDebugMode) {
          expect(e.category, DevLogCategory.network);
          expect(e.message, isNot(contains('secret-meta')));
        }
      }
      if (kDebugMode) {
        expect(log.visible(only: DevLogCategory.network), hasLength(1));
      }
    });

    test('环缓冲容量', () {
      for (var i = 0; i < 5; i++) {
        log.network(
          method: 'GET',
          url: 'https://e.example/$i',
          statusCode: 200,
        );
      }
      expect(log.entries.length, 3);
      expect(log.entries.first.message, contains('/4'));
    });
  });
}
