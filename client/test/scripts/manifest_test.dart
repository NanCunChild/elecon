import 'dart:convert';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> packageJson({String version = '0.1.0'}) => {
  'format': 'elecon-script/1',
  'manifest': {
    'sdkVersion': 1,
    'id': 'school.example',
    'version': version,
    'schoolId': 'a',
    'name': 'Example',
    'network': {
      'origins': ['https://school.example'],
    },
    'browser': false,
    'capabilities': [
      <String, dynamic>{
        'id': 'notice.list',
        'schema': 'elecon.notice.list',
        'schemaVersion': '1.1',
      },
    ],
  },
  'source': "export const capabilities={'notice.list':async()=>({items:[]})};",
};
void main() {
  test(
    'parsing does not execute source; identity is canonical and immutable',
    () {
      final json = packageJson()
        ..['source'] = "throw new Error('must not evaluate');";
      final pkg = ScriptPackage.parse(jsonEncode(json));
      final reordered = {
        'source': json['source'],
        'manifest': json['manifest'],
        'format': json['format'],
      };
      expect(
        pkg.digest,
        ScriptPackage.parse(
          const JsonEncoder.withIndent(' ').convert(reordered),
        ).digest,
      );
      expect(ScriptPackage.parse(pkg.encode()).digest, pkg.digest);
      expect(() => pkg.manifest.capabilities.clear(), throwsUnsupportedError);
      json['source'] = '// edit';
      expect(ScriptPackage.parse(jsonEncode(json)).digest, isNot(pkg.digest));
    },
  );
  test('format SDK fields and schema references are strict', () {
    for (final change in <void Function(Map<String, dynamic>)>[
      (j) => j['format'] = 'elecon-script/2',
      (j) => j['unknown'] = true,
      (j) => (j['manifest'] as Map)['sdkVersion'] = 99,
      (j) => (j['manifest'] as Map)['browser'] = 'false',
      (j) => (j['manifest'] as Map)['id'] = '../school',
      (j) => (j['manifest'] as Map)['capabilities'] = [],
      (j) =>
          (((j['manifest'] as Map)['capabilities'] as List).first
                  as Map)['schema'] =
              'elecon.grades.list',
      (j) =>
          (((j['manifest'] as Map)['capabilities'] as List).first
                  as Map)['params'] =
              {},
      (j) => ((j['manifest'] as Map)['capabilities'] as List).add({
        'id': 'notice.list',
        'schema': 'elecon.notice.list',
        'schemaVersion': '1.1',
      }),
      (j) =>
          (((j['manifest'] as Map)['capabilities'] as List).first
                  as Map)['schemaVersion'] =
              '99.0',
    ]) {
      final j = packageJson();
      change(j);
      expect(() => ScriptPackage.parse(jsonEncode(j)), throwsFormatException);
    }
  });
  test('SemVer compares numeric parts and rejects ambiguous forms', () {
    expect(compareScriptVersions('1.10.0', '1.9.99'), greaterThan(0));
    expect(compareScriptVersions('1.0.0', '1.0.0'), 0);
    for (final v in ['1.0', 'v1.0.0', '01.0.0', '1.0.0-beta', '1.0.0+1']) {
      expect(
        () => ScriptPackage.parse(jsonEncode(packageJson(version: v))),
        throwsFormatException,
      );
    }
  });
  test('package limit counts UTF8 bytes', () {
    final j = packageJson()..['source'] = '学' * (maxScriptPackageBytes ~/ 2);
    expect(() => ScriptPackage.parse(jsonEncode(j)), throwsFormatException);
  });
  test(
    'SDK 1 and 2 are explicit independent versions of the same package format',
    () {
      final sdk1 = ScriptPackage.parse(jsonEncode(packageJson()));
      final newer = packageJson(version: '0.2.0');
      (newer['manifest'] as Map)['sdkVersion'] = 2;
      final sdk2 = ScriptPackage.parse(jsonEncode(newer));
      expect(sdk1.manifest.sdkVersion, 1);
      expect(sdk2.manifest.sdkVersion, 2);
      expect(jsonDecode(sdk2.encode())['format'], 'elecon-script/1');
      expect(
        compareScriptVersions(sdk2.manifest.version, sdk1.manifest.version),
        greaterThan(0),
      );
      expect(sdk1.digest, isNot(sdk2.digest));
    },
  );
}
