import 'dart:convert';

import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/settings/settings_page.dart';
import 'package:elecon/ui/theme/theme_controller.dart';
import 'package:elecon/ui/theme/theme_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ScriptPackage _school(String id) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 1,
      'id': id,
      'version': '1.0.0',
      'schoolId': id,
      'name': 'School $id',
      'network': {'origins': []},
      'browser': false,
      'capabilities': [
        {
          'id': 'notice.list',
          'schema': 'elecon.notice.list',
          'schemaVersion': '1.1',
        },
      ],
    },
    'source':
        """export const capabilities={'notice.list':async(ctx)=>{
    const saved=await ctx.credentials.get('session');
    if(!saved) await ctx.credentials.set('session','SYNTHETIC_$id',{expiresAt:0});
    return {items:[],sourceSystem:saved ? saved.value : 'CREATED'};
  }};""",
  }),
);

void main() {
  testWidgets(
    'settings school switch preserves both school identities and uses saved-credential wording',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = (await tester.runAsync(() async {
        final controller = SessionController();
        await controller.bootstrap();
        for (final id in ['alpha', 'beta']) {
          final package = _school(id);
          await controller.installTrustedScript(
            package,
            approvedDigest: package.digest,
          );
          await controller.selectTrustedScriptSchool(id);
          final created = await controller.runCapability('notice.list');
          expect(created.ok, isTrue, reason: created.reason);
        }
        await controller.selectTrustedScriptSchool('alpha');
        return controller;
      }))!;
      addTearDown(session.dispose);
      final theme = ThemeController();
      addTearDown(theme.dispose);
      await tester.pumpWidget(
        ThemeScope(
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
              home: const SettingsPage(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('School credentials saved'), findsOneWidget);
      expect(find.text('Signed in'), findsNothing);
      expect(find.textContaining('1 credentials saved:'), findsOneWidget);
      await tester.tap(find.text('Switch school'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('keep saved credentials for all schools'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Switch'));
      await tester.pumpAndSettle();
      expect(session.selectedSchool, isNull);
      expect(session.credentialCount, 2);
      for (final id in ['alpha', 'beta']) {
        final result = await tester.runAsync(() async {
          await session.selectTrustedScriptSchool(id);
          return controllerRun(session);
        });
        expect((result! as Map)['sourceSystem'], 'SYNTHETIC_$id');
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}

Future<Object?> controllerRun(SessionController session) async {
  final run = await session.runCapability('notice.list');
  expect(run.ok, isTrue, reason: run.reason);
  return run.data;
}
