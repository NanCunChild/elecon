import 'dart:convert';
import 'dart:io';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:flutter_test/flutter_test.dart';
import 'manifest_test.dart' show packageJson;

Map<String, dynamic> localized(Object? localization, {int sdkVersion = 13}) {
  final json = packageJson();
  json['manifest'] = <String, dynamic>{
    ...json['manifest'] as Map,
    'sdkVersion': sdkVersion,
    'accounts': [],
    'localization': localization,
  };
  return json;
}

void main() {
  test('query controls are declared metadata but never a home preload', () {
    final json = packageJson();
    (json['manifest'] as Map)['capabilities'] = [
      {
        'id': 'query.controls',
        'schema': 'elecon.query.controls',
        'schemaVersion': '1.0',
      },
    ];
    expect(() => ScriptPackage.parse(jsonEncode(json)), returnsNormally);
    (json['manifest'] as Map)['home'] = [
      {'capability': 'query.controls', 'ttlSeconds': 60},
    ];
    (json['manifest'] as Map)['sdkVersion'] = 4;
    expect(() => ScriptPackage.parse(jsonEncode(json)), throwsFormatException);
  });

  test('Dart installation agrees with Node package localization admission', () {
    final fixture =
        jsonDecode(
              File(
                '../contract/golden/scripts/localization.json',
              ).readAsStringSync(),
            )
            as Map;
    for (final row in fixture['cases'] as List) {
      ScriptPackage action() => ScriptPackage.parse(
        jsonEncode(
          localized(row['localization'], sdkVersion: row['sdkVersion']),
        ),
      );
      expect(
        action,
        row['valid'] == true ? returnsNormally : throwsFormatException,
        reason: row['name'],
      );
    }
  });

  test(
    'translation changes require a new digest and dictionaries are immutable',
    () {
      final json = localized({
        'defaultLocale': 'en',
        'messages': {
          'en': {'greeting': 'Hi {name}'},
          'ru': {'greeting': 'Привет, {name}'},
        },
      });
      final package = ScriptPackage.parse(jsonEncode(json));
      expect(ScriptPackage.restore(package.encode()).digest, package.digest);
      final resources = package.manifest.localization!;
      expect(() => resources.messages.clear(), throwsUnsupportedError);
      expect(
        () => resources.messages['en']!['greeting'] = 'Changed',
        throwsUnsupportedError,
      );
      expect(() => resources.supportedLocales.clear(), throwsUnsupportedError);
      final declaration = (json['manifest'] as Map)['localization'] as Map;
      final messages = declaration['messages'] as Map;
      declaration['messages'] = {'ru': messages['ru'], 'en': messages['en']};
      expect(ScriptPackage.parse(jsonEncode(json)).digest, package.digest);
      (messages['ru'] as Map)['greeting'] = 'Здравствуйте, {name}';
      expect(
        ScriptPackage.parse(jsonEncode(json)).digest,
        isNot(package.digest),
      );
    },
  );

  test(
    'language resolution preserves script distinctions and canonicalizes preferences',
    () {
      final resource = ScriptPackage.parse(
        jsonEncode(
          localized({
            'defaultLocale': 'tr',
            'messages': {
              for (final language in [
                'tr',
                'zh',
                'zh-Hant',
                'zh-Hans-CN',
                'uz-Cyrl',
                'uz',
              ])
                language: {'title': 'Synthetic'},
            },
          }),
        ),
      ).manifest.localization!;
      expect(resource.resolveLocale('ZH_hant_tw'), 'zh-Hant');
      expect(resource.resolveLocale('zh-Hans-CN'), 'zh-Hans-CN');
      expect(resource.resolveLocale('zh-CN'), 'zh');
      expect(resource.resolveLocale('uz_CYRL_UZ'), 'uz-Cyrl');
      expect(resource.resolveLocale('uz-UZ'), 'uz');
      expect(resource.resolveLocale('fr'), 'tr');
      expect(resource.resolveLocale('zh-Hant-TW-x-private'), 'tr');
      expect(normalizeScriptLocale(null), isNull);
      expect(normalizeScriptLocale('en-us'), 'en-US');
      expect(normalizeScriptLocale('es_419'), 'es-419');
      expect(normalizeScriptLocale('en-US-u-ca-buddhist'), isNull);
    },
  );

  test(
    'resource budgets count UTF8 bytes and Unicode characters consistently',
    () {
      for (final messages in [
        {
          'en': {for (var i = 0; i < 1025; i++) 'key$i': 'x'},
        },
        {
          'en': {'title': 'x' * 4097},
        },
        {
          'en': {for (var i = 0; i < 100; i++) 'key$i': '学' * 1000},
        },
        {
          for (var i = 0; i < 33; i++)
            'en-${i.toString().padLeft(3, '0')}': {'title': 'x'},
        },
      ]) {
        expect(
          () => ScriptPackage.parse(
            jsonEncode(
              localized({
                'defaultLocale': messages.keys.first,
                'messages': messages,
              }),
            ),
          ),
          throwsFormatException,
        );
      }
      expect(
        () => ScriptPackage.parse(
          jsonEncode(
            localized({
              'defaultLocale': 'en',
              'messages': {
                'en': {'title': '🎒' * 4096},
              },
            }),
          ),
        ),
        returnsNormally,
      );
    },
  );
}
