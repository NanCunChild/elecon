import 'dart:convert';

import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/ui/scripts/script_install_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'manifest_test.dart' show packageJson;

const _messages = {
  'tr': {'greeting': 'Merhaba {name}'},
  'uz-Cyrl': {'greeting': 'Салом {name}'},
};

ScriptPackage _package({int sdk = 13, bool resources = true}) {
  final json = packageJson();
  json['manifest'] = <String, dynamic>{
    ...json['manifest'] as Map,
    'sdkVersion': sdk,
    'accounts': [],
    if (resources)
      'localization': {'defaultLocale': 'tr', 'messages': _messages},
  };
  // Opening an installation review must not execute the package source.
  json['source'] = "throw new Error('SYNTHETIC_SOURCE_MUST_NOT_EXECUTE');";
  return ScriptPackage.parse(jsonEncode(json));
}

Future<void> _showReview(
  WidgetTester tester,
  ScriptPackage package, {
  ValueChanged<bool>? onDecision,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final approved = await confirmScriptInstall(context, [package]);
              onDecision?.call(approved);
            },
            child: const Text('Review package'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Review package'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'SDK13 review exposes author-selected languages and expandable packaged translations',
    (tester) async {
      final package = _package();
      bool? approved;
      await _showReview(
        tester,
        package,
        onDecision: (value) => approved = value,
      );

      expect(find.text('Script languages: tr, uz-Cyrl'), findsOneWidget);
      expect(find.text('Default language: tr'), findsOneWidget);
      expect(find.text('View packaged translations'), findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);
      expect(approved, isNull);

      await tester.tap(find.text('View packaged translations'));
      await tester.pumpAndSettle();
      final preview = tester.widget<SelectableText>(
        find.byType(SelectableText),
      );
      expect(
        jsonDecode(preview.data!),
        _messages,
        reason: 'The review must show the exact approved package dictionaries.',
      );
      expect(find.text(package.source), findsNothing);
      expect(approved, isNull);

      await tester.tap(find.text('Trust and install'));
      await tester.pumpAndSettle();
      expect(approved, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  for (final sdk in [12, 13]) {
    testWidgets('SDK$sdk without localization has no language review area', (
      tester,
    ) async {
      bool? approved;
      await _showReview(
        tester,
        _package(sdk: sdk, resources: false),
        onDecision: (value) => approved = value,
      );

      expect(find.textContaining('Script languages:'), findsNothing);
      expect(find.textContaining('Default language:'), findsNothing);
      expect(find.text('View packaged translations'), findsNothing);
      expect(find.text('View source'), findsOneWidget);
      expect(find.byType(ExpansionTile), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(approved, isFalse);
    });
  }
}
