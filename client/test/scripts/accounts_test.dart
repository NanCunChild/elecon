import 'dart:convert';

import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'manifest_test.dart' show packageJson;

Map<String, dynamic> requirement() => {
  'id': 'campus',
  'name': 'Synthetic campus account',
  'instructions': 'Sign in on the school website.',
  'capabilities': ['notice.list'],
  'login': {
    'capability': 'notice.list',
    'params': {
      'scope': ['private'],
    },
  },
};
Map<String, dynamic> declared() {
  final root = jsonDecode(jsonEncode(packageJson())) as Map<String, dynamic>;
  (root['manifest'] as Map<String, dynamic>).addAll(<String, dynamic>{
    'sdkVersion': 11,
    'accounts': [requirement()],
  });
  return root;
}

void main() {
  test('a reviewed account login cannot execute a different digest', () async {
    final package = ScriptPackage.parse(jsonEncode(declared()));
    final session = SessionController();
    addTearDown(session.dispose);
    await session.installTrustedScript(package, approvedDigest: package.digest);
    await session.selectTrustedScriptSchool(package.manifest.id);
    final run = await session.runTrustedScript(
      package.manifest.id,
      'notice.list',
      expectedDigest: '0' * 64,
    );
    expect(run.ok, isFalse);
    expect(run.reason, 'script_not_authorized');
    expect(session.credentialCount, 0);
  });
  test(
    'SDK 11 distinguishes declared empty, legacy unspecified and external login',
    () {
      final old = ScriptPackage.parse(jsonEncode(packageJson()));
      expect(old.manifest.declaresAccounts, isFalse);
      final root = declared();
      (root['manifest'] as Map)['accounts'] = [];
      final empty = ScriptPackage.parse(jsonEncode(root));
      expect(empty.manifest.declaresAccounts, isTrue);
      expect(empty.manifest.accounts, isEmpty);
      final external = requirement()..remove('login');
      (root['manifest'] as Map)['accounts'] = [external];
      expect(
        ScriptPackage.parse(
          jsonEncode(root),
        ).manifest.accounts.single.loginCapability,
        isNull,
      );
    },
  );

  test('accounts and nested parameters are digest bound and immutable', () {
    final root = declared();
    final package = ScriptPackage.parse(jsonEncode(root));
    final account = package.manifest.accounts.single;
    expect(() => account.capabilities.clear(), throwsUnsupportedError);
    expect(
      () => (account.loginParams['scope'] as List).clear(),
      throwsUnsupportedError,
    );
    ((root['manifest'] as Map)['accounts'] as List).single['instructions'] =
        'Changed login instructions';
    expect(ScriptPackage.parse(jsonEncode(root)).digest, isNot(package.digest));
    expect(ScriptPackage.restore(package.encode()).digest, package.digest);
  });

  test(
    'rejects version mismatch, invalid references, duplicates and excessive inputs',
    () {
      for (final change in <void Function(Map)>[
        (m) => m['sdkVersion'] = 10,
        (m) => m.remove('accounts'),
        (m) => m['accounts'] = null,
        (m) => m['accounts'] = List.generate(17, (_) => requirement()),
        (m) => m['accounts'] = [requirement(), requirement()],
        (m) => m['accounts'][0]['unknown'] = true,
        (m) => m['accounts'][0]['id'] = '../account',
        (m) => m['accounts'][0]['name'] = 'Misleading\u202eaccount',
        (m) => m['accounts'][0]['instructions'] = 'first\nsecond',
        (m) => m['accounts'][0]['capabilities'] = [],
        (m) =>
            m['accounts'][0]['capabilities'] = ['notice.list', 'notice.list'],
        (m) => m['accounts'][0]['capabilities'] = ['messages.list'],
        (m) => m['accounts'][0]['login'] = {'capability': 'messages.session'},
        (m) => m['accounts'][0]['login'] = {
          'capability': 'notice.list',
          'params': {'value': '汉' * 1400},
        },
        (m) => m['accounts'][0]['login'] = {
          'capability': 'notice.list',
          'params': [],
        },
      ]) {
        final root = declared();
        change(root['manifest'] as Map);
        expect(
          () => ScriptPackage.parse(jsonEncode(root)),
          throwsFormatException,
        );
      }
    },
  );
}
