import 'dart:convert';
import 'dart:io';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:flutter_test/flutter_test.dart';
import '../utils/test_utils.dart' show repoPath;

void main() {
  final fixture =
      jsonDecode(
            File(
              repoPath('contract/golden/scripts/page-presentations.json'),
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  for (final testCase in fixture['cases'] as List) {
    test('SDK18 pages: ${testCase['name']}', () {
      final manifest = <String, dynamic>{
        ...fixture['baseManifest'] as Map<String, dynamic>,
        ...testCase['manifest'] as Map<String, dynamic>,
      };
      final encoded = jsonEncode({
        'format': 'elecon-script/1',
        'manifest': manifest,
        'source': 'export const capabilities={};',
      });
      if (testCase['valid'] != true) {
        expect(() => ScriptPackage.parse(encoded), throwsFormatException);
      } else {
        final package = ScriptPackage.parse(encoded);
        expect(
          package.manifest.pages.length,
          (manifest['pages'] as List).length,
        );
        expect(package.manifest.declaresPages, true);
        expect(() => package.manifest.pages.clear(), throwsUnsupportedError);
        expect(ScriptPackage.parse(package.encode()).digest, package.digest);
      }
    });
  }
}
