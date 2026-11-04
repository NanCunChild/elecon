import 'dart:async';
import 'dart:convert';

import 'package:elecon/core/navigation/app_feature.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/main.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/home/home_page.dart';
import 'package:elecon/ui/home/shortcut_feature_page.dart';
import 'package:elecon/ui/shell/main_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/school_fixture.dart';

const channel = MethodChannel('elecon/shortcuts');
const codec = StandardMethodCodec();

void nativeInitial(String? uri) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        channel,
        (call) async => switch (call.method) {
          'getInitialFeature' => uri,
          'canPin' => true,
          'pinFeature' => true,
          _ => null,
        },
      );
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
}

Future<void> send(WidgetTester tester, String uri) async {
  final done = Completer<void>();
  tester.binding.channelBuffers.push(
    channel.name,
    codec.encodeMethodCall(MethodCall('openFeature', uri)),
    (_) => done.complete(),
  );
  await done.future;
  await tester.pump();
}

Widget app(SessionController session) => EleconApp(
  sessionController: session,
  loadHomeSnapshot: () async =>
      const CampusSnapshot(schoolName: 'Synthetic', updatedAt: null),
);

ScriptPackage directory(String id, {String version = '1.0.0'}) =>
    ScriptPackage.parse(
      jsonEncode({
        'format': 'elecon-script/1',
        'manifest': {
          'sdkVersion': 16,
          'id': id,
          'schoolId': 'synthetic-shortcuts',
          'version': version,
          'name': 'Synthetic shortcuts',
          'browser': false,
          'network': {'origins': []},
          'accounts': [],
          'capabilities': [
            {
              'id': 'directory.phones',
              'schema': 'elecon.directory.phones',
              'schemaVersion': '1.0',
            },
          ],
          'home': [
            {
              'capability': 'directory.phones',
              'ttlSeconds': 86400,
              'preload': false,
            },
          ],
        },
        'source':
            '''export const capabilities={ 'directory.phones': async () => ({
    sourceUrl:'https://example.invalid/',verifiedDate:'2026-11-04',items:[{
      id:'synthetic-contact',name:'$id service',category:'Synthetic',phone:'10000',sourceUrl:'https://example.invalid/contact'
    }]
  })};''',
      }),
    );

Future<void> until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 200; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    if (ready()) return;
  }
  fail('Shortcut route did not settle');
}

void main() {
  testWidgets(
    'cold request waits for bootstrap and school selection; Back does not replay it',
    (tester) async {
      nativeInitial(AppFeature.schedule.uri);
      final storage = Completer<void>();
      final school = testSchool(schoolId: 'synthetic-shortcuts');
      final session = SessionController(
        initialSchools: [school],
        blobStoreProvider: () async {
          await storage.future;
          return null;
        },
      );
      await tester.pumpWidget(app(session));
      await tester.pump();
      expect(find.byType(ShortcutFeaturePage), findsNothing);
      expect(session.selectedSchool, isNull);
      storage.complete();
      await tester.pumpAndSettle();
      expect(find.byType(ShortcutFeaturePage), findsNothing);
      session.selectSchool(school);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ShortcutFeaturePage>(find.byType(ShortcutFeaturePage))
            .feature,
        AppFeature.schedule,
      );
      final context = tester.element(find.byType(ShortcutFeaturePage));
      expect(
        find.text(AppLocalizations.of(context).shortcutsUnavailable),
        findsOneWidget,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(ShortcutFeaturePage), findsNothing);
      expect(find.byType(MainShell), findsOneWidget);
    },
  );

  testWidgets(
    'warm requests replace the current feature, reject commands, and retain the active school',
    (tester) async {
      nativeInitial(null);
      final school = testSchool(schoolId: 'synthetic-shortcuts');
      final session = SessionController(initialSchools: [school]);
      await tester.runAsync(session.bootstrap);
      session.selectSchool(school);
      await tester.pumpWidget(app(session));
      await until(tester, () => find.byType(MainShell).evaluate().isNotEmpty);
      await send(tester, AppFeature.grades.uri);
      await until(
        tester,
        () =>
            find.byType(CircularProgressIndicator).evaluate().isEmpty &&
            find
                .byType(ShortcutFeaturePage)
                .evaluate()
                .any(
                  (e) =>
                      (e.widget as ShortcutFeaturePage).feature ==
                      AppFeature.grades,
                ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ShortcutFeaturePage>(find.byType(ShortcutFeaturePage))
            .feature,
        AppFeature.grades,
      );
      await send(tester, 'elecon://feature/climate?command=on');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ShortcutFeaturePage>(find.byType(ShortcutFeaturePage))
            .feature,
        AppFeature.grades,
      );
      await send(tester, AppFeature.exam.uri);
      await until(
        tester,
        () =>
            find.byType(CircularProgressIndicator).evaluate().isEmpty &&
            find
                .byType(ShortcutFeaturePage)
                .evaluate()
                .any(
                  (e) =>
                      (e.widget as ShortcutFeaturePage).feature ==
                      AppFeature.exam,
                ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ShortcutFeaturePage>(find.byType(ShortcutFeaturePage))
            .feature,
        AppFeature.exam,
      );
      expect(session.selectedSchool?.id, school.id);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(ShortcutFeaturePage), findsNothing);
    },
  );

  testWidgets(
    'cold feature opens the default provider and loses old data after a source update',
    (tester) async {
      nativeInitial(AppFeature.directory.uri);
      final session = SessionController();
      final primary = directory('synthetic-primary');
      final secondary = directory('synthetic-secondary');
      await tester.runAsync(() async {
        await session.bootstrap();
        for (final package in [primary, secondary]) {
          await session.installTrustedScript(
            package,
            approvedDigest: package.digest,
          );
        }
        await session.selectTrustedScriptSchool(primary.manifest.id);
        expect(
          (await session.runCapability(
            'directory.phones',
            params: const {},
            interactive: false,
          )).ok,
          isTrue,
        );
      });
      await tester.pumpWidget(app(session));
      await until(
        tester,
        () => find.text('synthetic-primary service').evaluate().isNotEmpty,
      );
      expect(find.text('synthetic-secondary service'), findsNothing);
      expect(
        SessionScope.of(tester.element(find.byType(ShortcutFeaturePage))),
        same(session),
      );
      await tester.runAsync(() async {
        final updated = directory(primary.manifest.id, version: '1.0.1');
        await session.installTrustedScript(
          updated,
          approvedDigest: updated.digest,
        );
      });
      await until(
        tester,
        () => find.text('synthetic-primary service').evaluate().isEmpty,
      );
      final context = tester.element(find.byType(ShortcutFeaturePage));
      expect(
        find.text(AppLocalizations.of(context).homeCardDataChanged),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('call-synthetic-contact')),
        findsNothing,
      );
    },
  );
}
