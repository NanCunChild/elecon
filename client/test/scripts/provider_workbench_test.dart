import 'dart:convert';

import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/scripts/script_workbench_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ScriptPackage _package(String id) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 2,
      'id': id,
      'version': '1.0.0',
      'schoolId': 'synthetic-providers',
      'name': id,
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
    'source': 'export const capabilities = {};',
  }),
);

void main() {
  testWidgets('workbench selects a same-name handler and restores the base', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = SessionController();
    addTearDown(session.dispose);
    await session.bootstrap();
    for (final id in ['base', 'extra']) {
      final package = _package(id);
      await session.installTrustedScript(
        package,
        approvedDigest: package.digest,
      );
    }
    await session.selectTrustedScriptSchool('base');
    await tester.pumpWidget(
      SessionScope(
        controller: session,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ScriptWorkbenchPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final use = find.byKey(const ValueKey('script-provider-extra'));
    await tester.ensureVisible(use);
    await tester.tap(use);
    await tester.pumpAndSettle();
    final registry = await session.scriptRegistry;
    expect(
      registry.provider('synthetic-providers', 'notice.list')!.manifest.id,
      'extra',
    );
    final restore = find.byKey(const ValueKey('script-provider-reset-extra'));
    await tester.ensureVisible(restore);
    await tester.tap(restore);
    await tester.pumpAndSettle();
    expect(
      registry.provider('synthetic-providers', 'notice.list')!.manifest.id,
      'base',
    );
    expect(
      find.byKey(const ValueKey('script-provider-reset-extra')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
