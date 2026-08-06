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

    test('redact=false 也永久剥离 query / fragment / userInfo / path session', () {
      expect(
        formatUrlForLog(
          'https://user:pass@ids.example.edu/auth;jsessionid=SECRET/next?ticket=SECRET#frag',
          redact: false,
        ),
        'https://ids.example.edu/auth/next',
      );
    });

    test('保留非默认 port 与 path', () {
      expect(
        formatUrlForLog('http://127.0.0.1:8080/echo?x=1', redact: true),
        'http://127.0.0.1:8080/echo',
      );
    });

    test('URL path 中的 ticket/token material 使用固定占位符', () {
      expect(
        formatUrlForLog(
          'https://ids.example.edu/callback/token/SECRET_MATERIAL_123456789',
        ),
        'https://ids.example.edu/callback/token/<redacted>',
      );
      expect(
        formatUrlForLog(
          'https://ids.example.edu/cas/ST-123-SECRET_MATERIAL_123456789',
        ),
        'https://ids.example.edu/cas/<redacted>',
      );
    });

    test('非法 URL', () {
      expect(formatUrlForLog('not a url', redact: true), '<invalid-url>');
      expect(sanitizeUrlForLog('not a url'), '<invalid-url>');
    });
  });

  group('maskCookieValue', () {
    test('redact=true 使用固定占位符', () {
      expect(maskCookieValue('secret-cookie', redact: true), '<redacted>');
    });

    test('redact=false 仍使用固定占位符', () {
      expect(maskCookieValue('secret-cookie', redact: false), '<redacted>');
    });
  });

  group('sanitizeLogMessage', () {
    test('净化 URL、认证 header、cookie 和裸 CAS ticket', () {
      const secret = 'SECRET_MATERIAL_123456789';
      final safe = sanitizeLogMessage(
        'failed https://user:pass@ids.example.edu/a;jsessionid=$secret/b'
        '?ticket=$secret#$secret\n'
        'Cookie: sid=$secret\nSet-Cookie: sid=$secret\n'
        'Authorization: Bearer $secret token=$secret '
        'ST-123-$secret',
      );
      expect(safe, isNot(contains(secret)));
      expect(safe, isNot(contains('user:pass')));
      expect(safe, contains('https://ids.example.edu/a/b'));
      expect(safe, contains('<redacted>'));
    });

    test('净化常见敏感键名赋值并使用固定占位符', () {
      const names = [
        'session_key',
        'school_session',
        'credential',
        'clientSecret',
        'api_key',
        'accessKey',
        'auth_key',
        'client-key',
        'private-key',
        'signingKey',
        'password',
        'passphrase',
      ];
      for (final name in names) {
        final short = sanitizeLogMessage('$name=x');
        final long = sanitizeLogMessage(
          '$name=${List.filled(200, 'x').join()}',
        );
        expect(short, '$name=<redacted>', reason: name);
        expect(long, short, reason: '$name must not disclose value length');
      }
    });

    test('净化 JSON 风格敏感键赋值', () {
      const secret = 'SECRET_MATERIAL_123456789';
      final safe = sanitizeLogMessage(
        '{"session_key":"$secret", "apiKey": "$secret"}',
      );
      expect(safe, isNot(contains(secret)));
      expect(safe, contains('session_key=<redacted>'));
      expect(safe, contains('apiKey=<redacted>'));
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

    test('setRedact(false) 不能关闭永久脱敏', () {
      log.setRedact(false);
      log.network(
        method: 'GET',
        url: 'https://ehall.example.edu/api?token=x',
        statusCode: 200,
      );
      expect(log.redact, isTrue);
      expect(log.entries.first.message, isNot(contains('token=x')));
      expect(
        log.entries.first.message,
        'GET https://ehall.example.edu/api → 200',
      );
    });

    test('network error 在截断前净化，不泄漏 secret 长度', () {
      final short = DevLog();
      final long = DevLog();
      short.network(
        method: 'GET',
        url: 'https://example.edu/',
        error: 'token=x',
      );
      long.network(
        method: 'GET',
        url: 'https://example.edu/',
        error: 'token=${List.filled(200, 'x').join()}',
      );
      expect(short.entries.single.message, long.entries.single.message);
      expect(short.entries.single.message, contains('token=<redacted>'));
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

    test('generic log/error/adapter 路径在入缓冲前净化', () {
      const secret = 'SECRET_MATERIAL_123456789';
      log.runtime('error token=$secret');
      log.adapter('error', 'Cookie: sid=$secret');
      log.log(
        DevLogCategory.network,
        'https://u:p@example.edu/x?ticket=$secret#$secret',
      );
      for (final entry in log.entries) {
        expect(entry.message, isNot(contains(secret)));
        expect(entry.message, isNot(contains('u:p')));
      }
    });

    test('debug console 只接收净化消息', () {
      const secret = 'SECRET_MATERIAL_123456789';
      final printed = <String>[];
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) printed.add(message);
      };
      try {
        log.runtime('failed https://u:p@example.edu/x?ticket=$secret');
      } finally {
        debugPrint = previous;
      }
      expect(printed.join('\n'), isNot(contains(secret)));
      expect(printed.join('\n'), isNot(contains('u:p')));
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
