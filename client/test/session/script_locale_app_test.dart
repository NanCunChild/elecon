import 'dart:convert';
import 'dart:io';

import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/main.dart';
import 'package:elecon/session/profile_controller.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/ui/theme/theme_controller.dart';
import 'package:elecon/ui/theme/theme_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<ThemeController> mountApp(
  WidgetTester tester,
  ProfileController profiles, {
  String? savedLocale,
}) async {
  final directory = Directory.systemTemp.createTempSync('elecon-locale-test-');
  addTearDown(() => directory.deleteSync(recursive: true));
  if (savedLocale != null) {
    File(
      '${directory.path}/theme_prefs.json',
    ).writeAsStringSync(jsonEncode({'localeTag': savedLocale}));
  }
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    channel,
    (_) async => directory.path,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    ),
  );
  await profiles.bootstrap();
  await tester.pumpWidget(EleconApp(profileController: profiles));
  final theme = tester.widget<ThemeScope>(find.byType(ThemeScope)).notifier!;
  for (var attempt = 0; !theme.isLoaded && attempt < 20; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(theme.isLoaded, isTrue);
  await tester.pumpAndSettle();
  return theme;
}

Locale coreLocale(WidgetTester tester) =>
    Localizations.localeOf(tester.element(find.byType(Scaffold).first));

void systemLocale(WidgetTester tester, Locale value) {
  // These mock properties are independent; real dispatchers keep them in sync.
  tester.binding.platformDispatcher.localeTestValue = value;
  tester.binding.platformDispatcher.localesTestValue = [value];
}

void main() {
  testWidgets('system locale reaches scripts even without a core translation', (
    tester,
  ) async {
    systemLocale(tester, const Locale('tr', 'TR'));
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    final profiles = ProfileController(
      createSession: (_) => SessionController(),
    );
    await mountApp(tester, profiles);

    expect(profiles.active.session.scriptLocale, 'tr-TR');
    expect(coreLocale(tester).languageCode, isNot('tr'));
    expect(
      AppLocalizations.supportedLocales,
      isNot(contains(const Locale('tr'))),
    );

    systemLocale(tester, const Locale('ru', 'RU'));
    await tester.pumpAndSettle();
    expect(profiles.active.session.scriptLocale, 'ru-RU');
    expect(coreLocale(tester).languageCode, 'ru');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'restored Persian preference overrides later system locale changes',
    (tester) async {
      systemLocale(tester, const Locale('tr', 'TR'));
      addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
      addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
      final profiles = ProfileController(
        createSession: (_) => SessionController(),
      );
      final theme = await mountApp(tester, profiles, savedLocale: 'fa');
      expect(profiles.active.session.scriptLocale, 'fa');
      expect(coreLocale(tester).languageCode, 'fa');
      expect(
        Directionality.of(tester.element(find.byType(Scaffold).first)),
        TextDirection.rtl,
      );

      systemLocale(tester, const Locale('uz', 'UZ'));
      await tester.pumpAndSettle();
      expect(profiles.active.session.scriptLocale, 'fa');
      expect(coreLocale(tester).languageCode, 'fa');

      await tester.runAsync(() => theme.setLocaleTag(null));
      await tester.pumpAndSettle();
      expect(profiles.active.session.scriptLocale, 'uz-UZ');
      expect(coreLocale(tester).languageCode, 'uz');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'new and previously active Profiles inherit the current preference',
    (tester) async {
      systemLocale(tester, const Locale('tr', 'TR'));
      addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
      addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
      final profiles = ProfileController(
        createSession: (_) => SessionController(),
      );
      final theme = await mountApp(tester, profiles);
      final first = profiles.active;
      expect(first.session.scriptLocale, 'tr-TR');

      await profiles.add();
      await tester.pumpAndSettle();
      final second = profiles.active;
      expect(second.id, isNot(first.id));
      expect(second.session.scriptLocale, 'tr-TR');

      await tester.runAsync(() => theme.setLocaleTag('fa'));
      await tester.pumpAndSettle();
      expect(second.session.scriptLocale, 'fa');
      await profiles.activate(first.id);
      await tester.pumpAndSettle();
      expect(first.session.scriptLocale, 'fa');
      expect(coreLocale(tester).languageCode, 'fa');

      await tester.runAsync(() => theme.setLocaleTag(null));
      await tester.pumpAndSettle();
      await profiles.activate(second.id);
      await tester.pumpAndSettle();
      expect(second.session.scriptLocale, 'tr-TR');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
