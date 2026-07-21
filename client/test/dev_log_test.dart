/// DevLog 脱敏、分类与可见性策略。
library;

import 'package:elecon/core/debug/dev_log.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatUrlForLog / sanitizeUrlForLog', () {
    test('redact=true 剥离 query / fragment / userInfo', () {
      expect(
        formatUrlForLog(
          'https://user:pass@ids.example.edu/auth?ticket=SECRET#frag',
          redact: true,
        ),
        'https://ids.example.edu/auth',
      );
      expect(
        sanitizeUrlForLog(
          'https://user:pass@ids.example.edu/auth?ticket=SECRET#frag',
        ),
        'https://ids.example.edu/auth',
      );
    });

    test('redact=false 保留 query / fragment，仍剥 userInfo', () {
      expect(
        formatUrlForLog(
          'https://user:pass@ids.example.edu/auth?ticket=SECRET#frag',
          redact: false,
        ),
        'https://ids.example.edu/auth?ticket=SECRET#frag',
      );
    });

    test('保留非默认 port 与 path', () {
      expect(
        formatUrlForLog('http://127.0.0.1:8080/echo?x=1', redact: true),
        'http://127.0.0.1:8080/echo',
      );
    });

    test('非法 URL', () {
      expect(formatUrlForLog('not a url', redact: true), '<invalid-url>');
      expect(sanitizeUrlForLog('not a url'), '<invalid-url>');
    });
  });

  group('maskCookieValue', () {
    test('redact=true 仅长度', () {
      expect(maskCookieValue('secret-cookie', redact: true), '<13B>');
    });

    test('redact=false 原文', () {
      expect(maskCookieValue('secret-cookie', redact: false), 'secret-cookie');
    });
  });

  group('DevLog', () {
    late DevLog log;

    setUp(() {
      log = DevLog(capacity: 8);
    });

    test('network 写入无参 URL + 状态（默认 redact）', () {
      log.network(
        method: 'get',
        url: 'https://ehall.example.edu/api?token=x',
        statusCode: 200,
        ok: true,
      );
      expect(log.entries, hasLength(1));
      expect(
        log.entries.first.message,
        'GET https://ehall.example.edu/api → 200',
      );
      expect(log.entries.first.category, DevLogCategory.network);
      expect(log.entries.first.ok, isTrue);
    });

    test('setRedact(false) 后 network 保留 query', () {
      log.setRedact(false);
      log.network(
        method: 'GET',
        url: 'https://ehall.example.edu/api?token=x',
        statusCode: 200,
      );
      expect(log.entries.first.message, contains('token=x'));
    });

    test('adapter 分类写入', () {
      log.adapter('info', 'hello from qjs');
      if (kDebugMode) {
        expect(log.entries, hasLength(1));
        expect(log.entries.first.category, DevLogCategory.adapter);
        expect(log.entries.first.message, '[info] hello from qjs');
      } else {
        expect(log.entries, isEmpty);
      }
    });

    test('webview 分类写入', () {
      log.webview('LoadStart ← https://ids.example.edu/login');
      if (kDebugMode) {
        expect(log.entries, hasLength(1));
        expect(log.entries.first.category, DevLogCategory.webview);
      } else {
        expect(log.entries, isEmpty);
      }
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
      final small = DevLog(capacity: 3);
      for (var i = 0; i < 5; i++) {
        small.network(
          method: 'GET',
          url: 'https://e.example/$i',
          statusCode: 200,
        );
      }
      expect(small.entries.length, 3);
      expect(small.entries.first.message, contains('/4'));
    });
  });
}
