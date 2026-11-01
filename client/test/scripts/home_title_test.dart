import 'dart:convert';
import 'dart:io';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/scripts/registry.dart';
import 'package:flutter_test/flutter_test.dart';
import '../utils/test_utils.dart' show repoPath;

void main() {
  final fixture =
      jsonDecode(
            File(
              repoPath('contract/golden/scripts/home-titles.json'),
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final base = fixture['baseManifest'] as Map<String, dynamic>;
  ScriptPackage package(Map<String, dynamic> patch) => ScriptPackage.parse(
    jsonEncode({
      'format': 'elecon-script/1',
      'manifest': {...base, ...patch},
      'source':
          "export const capabilities={'notice.list':async()=>({items:[]})};",
    }),
  );
  for (final raw in fixture['cases'] as List) {
    final testCase = raw as Map<String, dynamic>;
    test('SDK7 shared title: ${testCase['name']}', () {
      final fields = testCase['manifest'] as Map<String, dynamic>;
      if (testCase['valid'] != true) {
        expect(() => package(fields), throwsFormatException);
      } else {
        final parsed = package(fields);
        expect(parsed.manifest.homeTitle, fields['homeTitle']);
        expect(ScriptPackage.parse(parsed.encode()).digest, parsed.digest);
      }
    });
  }
  test('title changes bind to digest and retain stable ownership', () async {
    final registry = await ScriptRegistry.open(null);
    final first = package({'homeTitle': 'First campus'});
    final candidate = package({
      'id': 'candidate',
      'homeTitle': 'Candidate campus',
    });
    await registry.install(first, approvedDigest: first.digest);
    await registry.install(candidate, approvedDigest: candidate.digest);
    await registry.setProviderOverride(
      'header-school',
      'notice.list',
      'candidate',
    );
    expect(registry.homeTitleForSchool('header-school'), 'First campus');
    expect(
      registry.homeTitleForSchool('other', packageId: 'school.header'),
      isNull,
    );
    final update = package({'version': '1.0.1', 'homeTitle': 'Renamed campus'});
    expect(update.digest, isNot(first.digest));
    await registry.install(update, approvedDigest: update.digest);
    expect(registry.homeTitleForSchool('header-school'), 'Renamed campus');
    await registry.setEnabled('school.header', false);
    expect(registry.homeTitleForSchool('header-school'), isNull);
    expect(
      registry.homeTitleForSchool('header-school', packageId: 'school.header'),
      isNull,
    );
    await registry.remove('school.header');
    expect(registry.homeTitleForSchool('header-school'), isNull);
  });
}
