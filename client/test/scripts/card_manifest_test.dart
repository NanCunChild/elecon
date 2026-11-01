import 'dart:convert';
import 'dart:io';

import 'package:elecon/core/credential/secure_store.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:flutter_test/flutter_test.dart';

import '../utils/test_utils.dart' show repoPath;

void main() {
  final fixture =
      jsonDecode(
            File(
              repoPath('contract/golden/scripts/card-presentations.json'),
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final base = fixture['baseManifest'] as Map<String, dynamic>;
  for (final raw in fixture['cases'] as List) {
    final testCase = raw as Map<String, dynamic>;
    test('SDK6 shared card declaration: ${testCase['name']}', () {
      final manifest = <String, dynamic>{
        ...base,
        ...testCase['manifest'] as Map<String, dynamic>,
      };
      final text = jsonEncode({
        'format': 'elecon-script/1',
        'manifest': manifest,
        'source': "throw new Error('must not evaluate during parse');",
      });
      if (testCase['valid'] != true) {
        expect(() => ScriptPackage.parse(text), throwsFormatException);
        return;
      }
      final package = ScriptPackage.parse(text);
      expect(package.manifest.sdkVersion, 6);
      final cards = manifest['cards'] as List? ?? [];
      expect(package.manifest.cards.length, cards.length);
      for (var i = 0; i < cards.length; i++) {
        expect(package.manifest.cards[i].type, cards[i]['type']);
        expect(
          package.manifest.cards[i].defaultVariant,
          cards[i]['defaultVariant'],
        );
      }
      expect(() => package.manifest.cards.clear(), throwsUnsupportedError);
      expect(ScriptPackage.parse(package.encode()).digest, package.digest);
    });
  }

  test('presentation changes require a new approved content digest', () {
    Map<String, dynamic> input(String variant) => {
      'format': 'elecon-script/1',
      'manifest': {
        ...base,
        'cards': [
          {'type': 'notice', 'defaultVariant': variant},
        ],
      },
      'source': 'export const capabilities = {};',
    };
    final compact = ScriptPackage.parse(jsonEncode(input('compact')));
    final expanded = ScriptPackage.parse(jsonEncode(input('expanded')));
    expect(compact.digest, isNot(expanded.digest));
  });

  test('SDK6 keeps SDK2 credential addresses without adding authority', () {
    final store = CredentialStore(
      store: InMemorySecureStore(releaseMode: false),
    );
    final original = ScriptCredentials(
      store: store,
      schoolId: 'fixture',
      scriptId: 'school.fixture',
      sdkVersion: 2,
    );
    original.set('session', 'SYNTHETIC_SESSION');
    final sdk6 = ScriptCredentials(
      store: store,
      schoolId: 'fixture',
      scriptId: 'school.fixture',
      sdkVersion: 6,
    );
    expect(sdk6.get('session')!['value'], 'SYNTHETIC_SESSION');
    final otherSchool = ScriptCredentials(
      store: store,
      schoolId: 'other',
      scriptId: 'school.fixture',
      sdkVersion: 6,
    );
    expect(otherSchool.get('session'), isNull);
    expect(
      () => ScriptCredentials(
        store: store,
        schoolId: 'fixture',
        scriptId: 'school.fixture',
        sdkVersion: 8,
      ),
      throwsA(isA<ScriptCredentialException>()),
    );
  });
}
