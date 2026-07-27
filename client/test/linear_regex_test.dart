/// ADR-023 deterministic regex subset tests.
///
/// Security-sensitive broker path. AI drafted; requires human security review
/// before merge (AGENTS.md section 1).
library;

import 'package:elecon/core/broker/dataflow.dart';
import 'package:elecon/core/broker/linear_regex.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final accepted = <(String, String, int, String)>[
    ('client_id=([a-z0-9]+)', 'x client_id=ab12_', 1, 'ab12'),
    ('[0-9]{4}', 'year=2026', 0, '2026'),
    ('zzz([0-9]+)', '--zzz42!', 1, '42'),
    (r'id=(\w+)', 'id=user_7', 1, 'user_7'),
    (r'session_key=(\w+)', 'session_key=K_9', 1, 'K_9'),
    (r"client_id:'(\w+)'", "client_id:'abc_1'", 1, 'abc_1'),
    (r'seed=(\w+)', 'seed=a9', 1, 'a9'),
    (r'seed=(.+)$', 'prefix seed=a b', 1, 'a b'),
    (r'token=(\w+)', 'token=T0', 1, 'T0'),
    (r'v=(\w+)', 'v=x_1', 1, 'x_1'),
    (r'^id=(\w+)$', 'id=root', 1, 'root'),
    ('(.)', '😀', 1, '😀'),
  ];

  test('matches current patterns, captures, and anchors', () {
    for (final c in accepted) {
      final match = matchLinearRegex(parseLinearRegex(c.$1), c.$2);
      expect(match, isNotNull, reason: c.$1);
      expect(match!.group(c.$3), c.$4, reason: c.$1);
    }
    expect(
      matchLinearRegex(parseLinearRegex(r'^id=(\w+)$'), 'xid=root'),
      isNull,
    );
    expect(
      matchLinearRegex(
        parseLinearRegex(r'seed=(.+)$'),
        'header\nseed=value\n',
      )?.group(1),
      'value',
    );
  });

  test('rejects constructs outside the proved subset', () {
    for (final pattern in [
      r'(a|aa)+$',
      'a*a*b',
      '(?=a)a',
      '(?<=a)b',
      r'(a)\1',
      r'(\w)+',
      r"(\w+)'",
      'a+?',
      'a+b',
      r'\bword',
      r'[\q]',
      r'\s(.+)$',
    ]) {
      expect(
        () => parseLinearRegex(pattern),
        throwsA(isA<LinearRegexSyntaxException>()),
        reason: pattern,
      );
    }
  });

  test('runtime fails closed and preserves group out-of-range behavior', () {
    expect(
      () => extractHandle(
        BindDecl(
          varName: 'x',
          from: 'A',
          source: 'regex',
          extract: {'pattern': '(a|aa)+\$'},
        ),
        const RawResponse(status: 200, headers: {}, body: 'aaaaab'),
      ),
      throwsA(
        isA<DataflowException>().having(
          (error) => error.code,
          'code',
          'extract_bad_pattern',
        ),
      ),
    );
    expect(
      () => extractHandle(
        BindDecl(
          varName: 'x',
          from: 'A',
          source: 'regex',
          extract: {'pattern': '(a)', 'group': 2},
        ),
        const RawResponse(status: 200, headers: {}, body: 'a'),
      ),
      throwsA(
        isA<DataflowException>().having(
          (error) => error.code,
          'code',
          'extract_not_found',
        ),
      ),
    );
  });
}
