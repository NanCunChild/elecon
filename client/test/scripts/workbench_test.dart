import 'dart:convert';

import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/scripts/script_workbench_page.dart';
import 'package:elecon/ui/shell/main_shell.dart';
import 'package:elecon/ui/theme/theme_controller.dart';
import 'package:elecon/ui/theme/theme_scope.dart';
import 'package:flutter/material.dart';
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
