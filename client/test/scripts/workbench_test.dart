import 'dart:convert';

import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/scripts/script_workbench_page.dart';
import 'package:elecon/ui/scripts/bundled_scripts.dart';
import 'package:elecon/ui/scripts/script_presenter.dart';
import 'package:elecon/core/scripts/browser.dart';
import 'package:elecon/ui/onboarding/onboarding_page.dart';
import 'package:elecon/ui/shell/main_shell.dart';
import 'package:elecon/ui/theme/theme_controller.dart';
import 'package:elecon/ui/theme/theme_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

String _package({
  String version = '1.0.0',
  String id = 'ui-school',
  String school = 'ui-example',
  String title = 'Installed notice',
  List<String> capabilities = const ['notice.list'],
}) => jsonEncode({
  'format': 'elecon-script/1',
  'manifest': {
    'sdkVersion': 1,
    'id': id,
    'version': version,
    'schoolId': school,
    'name': 'UI School $school',
    'network': {
      'origins': ['https://school.example'],
    },
    'browser': false,
    'capabilities': [
      for (final cap in capabilities)
        {
          'id': cap,
          'schema': 'elecon.$cap',
          'schemaVersion': cap == 'notice.list' || cap == 'grades.list'
              ? '1.1'
              : '1.0',
        },
    ],
  },
  'source':
      '''export const capabilities={
    "notice.list": async(ctx)=>({items:[{id:"local",title:${jsonEncode(title)},category:"academic",source:"Local"}]}),
    "generic.section": async(ctx)=>({sectionId:"local",title:"Generic local output"}),
    "grades.list": async(ctx)=>({term:"2026-1",items:[]})
  };''',
});

Widget _app(SessionController session, Widget home) {
  final theme = ThemeController();
  addTearDown(theme.dispose);
  return ThemeScope(
    controller: theme,
    child: SessionScope(
      controller: session,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          useMaterial3: true,
          splashFactory: NoSplash.splashFactory,
        ),
        home: home,
      ),
    ),
  );
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() completed) async {
  // Real QuickJS isolates and asset IO need real event-loop turns; callbacks
  // also need widget binding microtasks/frames between those turns.
  for (var attempt = 0; attempt < 300; attempt++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (completed()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  fail('The expected script UI state did not arrive');
}

void main() {
  Future<void> prepare(WidgetTester tester) async {
    // CachingAssetBundle futures must not retain a previous test's fake zone.
    rootBundle.clear();
    tester.view.physicalSize = const Size(1100, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> import(
    WidgetTester tester,
    String source, {
    bool trust = true,
  }) async {
    await tester.enterText(find.byType(TextField).first, source);
    await tester.tap(find.text('Review and install'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Trust and install this script?'), findsOneWidget);
    await tester.tap(find.text(trust ? 'Trust and install' : 'Cancel'));
    await tester.pumpAndSettle();
  }

  testWidgets('browser permission alone never creates a page or native lease', (
    tester,
  ) async {
    await prepare(tester);
    final session = SessionController();
    addTearDown(session.dispose);
    await session.bootstrap();
    final raw = jsonDecode(_package()) as Map<String, dynamic>;
    (raw['manifest'] as Map)['browser'] = true;
    final package = ScriptPackage.parse(jsonEncode(raw));
    Object? result;
    await tester.pumpWidget(
      _app(
        session,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await presentScriptBrowser(
                context,
                package,
                (_) async => 'cached',
              );
            },
            child: const Text('Read cached'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Read cached'));
    await tester.pumpAndSettle();
    expect(result, 'cached');
    expect(ScriptBrowserLease.busy, isFalse);
    expect(find.text('School page'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'bundled choices require consent and install one unified package per school',
    (tester) async {
      await prepare(tester);
      final session = SessionController();
      addTearDown(session.dispose);
      await session.bootstrap();
      await tester.pumpWidget(_app(session, const ScriptWorkbenchPage()));
      await tester.pumpAndSettle();
      expect(find.text('Xidian University (undergraduate)'), findsOneWidget);
      for (final school in bundledScriptSchools) {
        if (school == bundledScriptSchools.last) {
          await tester.tap(
            find.byType(DropdownButtonFormField<BundledScriptSchool>),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Xidian University (postgraduate)').last);
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text('Review bundled school scripts'));
        await _pumpUntil(
          tester,
          () =>
              find.text('Trust and install this script?').evaluate().isNotEmpty,
        );
        final before = (await session.scriptRegistry).installations.length;
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect((await session.scriptRegistry).installations.length, before);
        await tester.tap(find.text('Review bundled school scripts'));
        await _pumpUntil(
          tester,
          () =>
              find.text('Trust and install this script?').evaluate().isNotEmpty,
        );
        expect(
          find.textContaining('https://xxcapp.xidian.edu.cn'),
          findsWidgets,
        );
        await tester.tap(find.text('Trust and install'));
        await _pumpUntil(tester, () => session.selectedSchool?.id == school.id);
        await tester.pumpAndSettle();
        final registry = await session.scriptRegistry;
        expect(registry.find(school.dataId)?.enabled, isTrue);
        expect(registry.find(school.loginId), isNull);
        expect(session.selectedSchool?.displayName, isNot(contains('登录')));
      }
      expect((await session.scriptRegistry).installations, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'bundled school selection preserves a newer installed data package',
    (tester) async {
      await prepare(tester);
      final session = SessionController();
      addTearDown(session.dispose);
      await session.bootstrap();
      final school = bundledScriptSchools.first;
      final newer = ScriptPackage.parse(
        _package(id: school.dataId, school: school.id, version: '9.0.0'),
      );
      await session.installTrustedScript(newer, approvedDigest: newer.digest);
      await tester.pumpWidget(_app(session, const ScriptWorkbenchPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review bundled school scripts'));
      await _pumpUntil(
        tester,
        () => find.text('Trust and install this script?').evaluate().isNotEmpty,
      );
      expect(find.textContaining('9.0.0'), findsWidgets);
      await tester.tap(find.text('Trust and install'));
      await _pumpUntil(tester, () => session.selectedSchool?.id == school.id);
      await tester.pumpAndSettle();
      expect(
        (await session.scriptRegistry).find(school.dataId)?.package.digest,
        newer.digest,
      );
      expect((await session.scriptRegistry).find(school.loginId), isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'onboarding shows the two current choices instead of the legacy Xidian identity',
    (tester) async {
      await prepare(tester);
      final session = SessionController();
      addTearDown(session.dispose);
      await session.bootstrap();
      final legacy = ScriptPackage.parse(
        _package(id: 'legacy-script', school: 'xidian'),
      );
      await session.installTrustedScript(legacy, approvedDigest: legacy.digest);
      await tester.pumpWidget(_app(session, const OnboardingPage()));
      await tester.pumpAndSettle();
      expect(find.text('Xidian University (undergraduate)'), findsOneWidget);
      expect(find.text('Xidian University (postgraduate)'), findsOneWidget);
      expect(find.text('UI School xidian'), findsNothing);
      expect((await session.scriptRegistry).find('legacy-script'), isNotNull);
      expect(session.availableSchools.single.id, 'xidian');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'approved unified update retires the old login install and keeps credentials',
    (tester) async {
      await prepare(tester);
      final session = SessionController();
      addTearDown(session.dispose);
      await session.bootstrap();
      final school = bundledScriptSchools.first;
      final raw =
          jsonDecode(
                _package(
                  id: school.loginId,
                  school: school.id,
                  capabilities: ['generic.section'],
                ),
              )
              as Map<String, dynamic>;
      raw['source'] =
          "export const capabilities={'generic.section':async(ctx)=>{await ctx.credentials.set('saved','SYNTHETIC_RETAINED',{namespace:'xidian.auth'});return {sectionId:'login',title:'Saved'};}};";
      final legacy = ScriptPackage.parse(jsonEncode(raw));
      await session.installTrustedScript(legacy, approvedDigest: legacy.digest);
      await session.selectTrustedScriptSchool(legacy.manifest.id);
      final saved = await tester.runAsync(
        () => session.runTrustedScript(legacy.manifest.id, 'generic.section'),
      );
      expect(saved!.ok, isTrue, reason: saved.reason);
      expect(session.credentialCount, 1);
      await tester.pumpWidget(_app(session, const ScriptWorkbenchPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review bundled school scripts'));
      await _pumpUntil(
        tester,
        () => find.text('Trust and install this script?').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect((await session.scriptRegistry).find(school.loginId), isNotNull);
      await tester.tap(find.text('Review bundled school scripts'));
      await _pumpUntil(
        tester,
        () => find.text('Trust and install this script?').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('Trust and install'));
      await _pumpUntil(
        tester,
        () => find.text('Trust and install this script?').evaluate().isEmpty,
      );
      await tester.pumpAndSettle();
      expect((await session.scriptRegistry).find(school.loginId), isNull);
      expect(
        (await session.scriptRegistry).find(school.dataId)?.enabled,
        isTrue,
      );
      expect(session.credentialCount, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('onboarding offers both built-in identities before any import', (
    tester,
  ) async {
    await prepare(tester);
    final session = SessionController();
    addTearDown(session.dispose);
    await session.bootstrap();
    await tester.pumpWidget(_app(session, const OnboardingPage()));
    await tester.pumpAndSettle();
    expect((await session.scriptRegistry).installations, isEmpty);
    expect(find.text('Xidian University (undergraduate)'), findsOneWidget);
    await tester.tap(find.text('Xidian University (postgraduate)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select and continue'));
    await _pumpUntil(
      tester,
      () => find.text('Trust and install this script?').evaluate().isNotEmpty,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(session.selectedSchool, isNull);
    await tester.tap(find.text('Select and continue'));
    await _pumpUntil(
      tester,
      () => find.text('Trust and install this script?').evaluate().isNotEmpty,
    );
    await tester.tap(find.text('Trust and install'));
    await _pumpUntil(
      tester,
      () => session.selectedSchool?.id == 'xidian_postgraduate',
    );
    await tester.pumpAndSettle();
    expect((await session.scriptRegistry).installations, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'local source stays uninstalled until approval, then selects and runs its school',
    (tester) async {
      await prepare(tester);
      final session = SessionController();
      addTearDown(session.dispose);
      await session.bootstrap();
      await tester.pumpWidget(_app(session, const ScriptWorkbenchPage()));
      await tester.pumpAndSettle();
      final source = _package();
      await tester.enterText(find.byType(TextField).first, source);
      await tester.tap(find.text('Review and install'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('https://school.example'), findsOneWidget);
      expect(
        find.textContaining('can read, change or disclose credentials'),
        findsOneWidget,
      );
      expect((await session.scriptRegistry).installations, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(session.availableSchools, isEmpty);

      await import(tester, source);
      expect((await session.scriptRegistry).installations, hasLength(1));
      expect(session.availableSchools.single.id, 'ui-example');
      await tester.tap(find.text('Use this school'));
      await tester.pumpAndSettle();
      expect(session.selectedSchool?.id, 'ui-example');
      await tester.tap(find.text('Run'));
      await _pumpUntil(tester, () => find.text('Result').evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(find.text('Result'), findsOneWidget);
      expect(find.textContaining('Installed notice'), findsWidgets);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(
        find.text('Result'),
        findsNothing,
        reason:
            'Revoking the producer must remove its previously displayed private result',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'package update removes a previously chosen capability without dropdown assertion',
    (tester) async {
      await prepare(tester);
      final session = SessionController();
      addTearDown(session.dispose);
      await session.bootstrap();
      await tester.pumpWidget(_app(session, const ScriptWorkbenchPage()));
      await tester.pumpAndSettle();
      await import(
        tester,
        _package(capabilities: ['notice.list', 'generic.section']),
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('generic.section').last);
      await tester.pumpAndSettle();
      await import(tester, _package(version: '1.0.1'));
      expect(
        (await session.scriptRegistry)
            .find('ui-school')!
            .package
            .manifest
            .version,
        '1.0.1',
      );
      expect(find.text('generic.section'), findsNothing);
      expect(find.text('notice.list'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'disable and uninstall take effect from the installed script controls',
    (tester) async {
      await prepare(tester);
      final session = SessionController();
      addTearDown(session.dispose);
      await session.bootstrap();
      await tester.pumpWidget(_app(session, const ScriptWorkbenchPage()));
      await tester.pumpAndSettle();
      await import(tester, _package());
      await tester.tap(find.text('Use this school'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(session.availableSchools, isEmpty);
      expect(session.selectedSchool, isNull);
      expect(
        (await session.scriptRegistry).find('ui-school')!.enabled,
        isFalse,
      );
      await tester.tap(find.text('Uninstall'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('School credentials remain'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Uninstall'));
      await tester.pumpAndSettle();
      expect((await session.scriptRegistry).installations, isEmpty);
      expect(find.text('No scripts installed'), findsOneWidget);
    },
  );

  testWidgets(
    'main shell exposes grade capability when the school has no notice provider',
    (tester) async {
      await prepare(tester);
      final session = SessionController();
      addTearDown(session.dispose);
      await session.bootstrap();
      final package = ScriptPackage.parse(
        _package(capabilities: ['grades.list']),
      );
      await session.installTrustedScript(
        package,
        approvedDigest: package.digest,
      );
      await session.selectTrustedScriptSchool(package.manifest.id);
      await tester.pumpWidget(_app(session, const MainShell()));
      await tester.pumpAndSettle();
      expect(find.text('成绩'), findsOneWidget);
      expect(find.text('查看成绩'), findsOneWidget);
      expect(find.text('No data yet'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('switching local schools removes the previous school snapshot', (
    tester,
  ) async {
    await prepare(tester);
    final session = SessionController();
    addTearDown(session.dispose);
    await session.bootstrap();
    for (final id in ['alpha', 'beta']) {
      final package = ScriptPackage.parse(
        _package(id: id, school: id, title: '$id notice'),
      );
      await session.installTrustedScript(
        package,
        approvedDigest: package.digest,
      );
    }
    await session.selectTrustedScriptSchool('alpha');
    await tester.pumpWidget(_app(session, const MainShell()));
    await _pumpUntil(
      tester,
      () => find.text('alpha notice').evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    expect(find.text('alpha notice'), findsOneWidget);
    await session.selectTrustedScriptSchool('beta');
    await _pumpUntil(
      tester,
      () => find.text('beta notice').evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    expect(find.text('beta notice'), findsOneWidget);
    expect(find.text('alpha notice'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
