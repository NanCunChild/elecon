import 'dart:convert';
import 'dart:io';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final vectors =
      jsonDecode(
            File(
              '../contract/golden/scripts/interactions.json',
            ).readAsStringSync(),
          )
          as Map;
  const source = "throw new Error('SYNTHETIC_SOURCE_MUST_NOT_EXECUTE');";
  ScriptPackage parse(Map manifest) => ScriptPackage.parse(
    jsonEncode({
      'format': 'elecon-script/1',
      'manifest': manifest,
      'source': source,
    }),
  );
  test('SDK14 Node packaging and Dart installation agree on declarations', () {
    for (final row in vectors['cases'] as List) {
      expect(
        () => parse(row['manifest']),
        row['valid'] == true ? returnsNormally : throwsFormatException,
        reason: row['name'],
      );
    }
  });
  test('HTML bytes are bounded, immutable and part of execution identity', () {
    final base =
        (vectors['cases'] as List).firstWhere(
              (row) => row['name'] == 'bounded web template',
            )['manifest']
            as Map;
    final before = parse(base);
    expect(() => before.manifest.webContent.clear(), throwsUnsupportedError);
    final changed = {
      ...base,
      'webContent': [
        {'id': 'form', 'title': 'Form', 'html': '<p>Changed</p>'},
      ],
    };
    expect(parse(changed).digest, isNot(before.digest));
    expect(ScriptPackage.restore(before.encode()).digest, before.digest);
    for (final html in ['x' * 262145, '学' * 90000, '\u0000']) {
      expect(
        () => parse({
          ...base,
          'webContent': [
            {'id': 'form', 'title': 'Form', 'html': html},
          ],
        }),
        throwsFormatException,
      );
    }
    expect(
      () => parse({
        ...base,
        'webContent': [
          for (var i = 0; i < 3; i++)
            {'id': 'form$i', 'title': 'Form', 'html': 'x' * 180000},
        ],
      }),
      throwsFormatException,
    );
  });
}
