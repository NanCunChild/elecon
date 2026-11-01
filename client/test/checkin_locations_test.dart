import 'dart:convert';

import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/ui/community/checkin_locations.dart';
import 'package:elecon/ui/community/community_pages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ScriptPackage package({String schema = '1.1'}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 9,
      'id': 'synthetic',
      'schoolId': 'synthetic',
      'version': '1.0.0',
      'name': 'Synthetic service',
      'network': {'origins': []},
      'browser': false,
      'capabilities': [
        for (final id in [
          'messages.session',
          'messages.list',
          'attendance.checkin',
        ])
          {
            'id': id,
            'schema': 'elecon.$id',
            'schemaVersion': id == 'attendance.checkin' ? schema : '1.0',
          },
      ],
    },
    'source': '''export const capabilities={
    'messages.session':async()=>({serviceId:'synthetic',serviceName:'Synthetic',status:'authenticated',accountId:'synthetic'}),
    'attendance.checkin':async(ctx,p)=>{
      if(Object.keys(p).length===0) return {status:'unsupported',reason:'location_required'};
      await ctx.credentials.set('submitted','synthetic');
      if(p.location?.address==='Synthetic address' && p.location.latitude===12.3456 && p.location.coordinateSystem==='service')
        return {status:'rejected',reason:'location_rejected'};
      return {status:'unsupported',reason:'location_required'};
    }
  };''',
  }),
);

Widget app(
  Widget home, {
  String language = 'en',
  Brightness brightness = Brightness.light,
  double scale = 1,
}) => MaterialApp(
  locale: Locale(language),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  theme: ThemeData(brightness: brightness),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: home,
);
Future<void> settle(WidgetTester tester) async {
  // Registry and QuickJS work use the real zone; don't wait on an animated
  // progress indicator while starving its native completion.
  for (var i = 0; i < 150; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}

Future<void> tapText(WidgetTester tester, String text) async {
  final target = find.text(text).last;
  await tester.ensureVisible(target);
  await tester.runAsync(() => tester.tap(target));
  await settle(tester);
}

void main() {
  for (final language in ['zh', 'en']) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'place editor and matrix support narrow large text: $language $brightness',
        (tester) async {
          tester.view.physicalSize = const Size(320, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final session = SessionController();
          addTearDown(session.dispose);
          final p = package();
          await tester.runAsync(() async {
            await session.installTrustedScript(p, approvedDigest: p.digest);
            await session.selectTrustedScriptSchool('synthetic');
          });
          AttendancePlace? selected;
          final page = Scaffold(
            body: SingleChildScrollView(
              child: CheckinLocations(
                session: session,
                package: p,
                enabled: true,
                onSelected: (p) => selected = p,
              ),
            ),
          );
          await tester.pumpWidget(
            app(page, language: language, brightness: brightness, scale: 2),
          );
          await settle(tester);
          final l10n = AppLocalizations.of(
            tester.element(find.byType(CheckinLocations)),
          );
          await tapText(tester, l10n.checkinPlaceAdd);
          await tapText(tester, l10n.checkinPlaceSave);
          expect(find.text(l10n.checkinPlaceRequired), findsNWidgets(2));
          final fields = find.byType(TextFormField);
          for (final entry in [
            'Synthetic classroom',
            'Synthetic address',
            '91',
            '45.6789',
          ].indexed) {
            await tester.enterText(fields.at(entry.$1), entry.$2);
          }
          await tapText(tester, l10n.checkinPlaceSave);
          expect(find.text(l10n.checkinCoordinateInvalid), findsOneWidget);
          await tester.enterText(fields.at(2), '12.3456');
          await tapText(tester, l10n.checkinPlaceSave);
          expect(selected, isNull);
          expect(session.isLoggedIn, isFalse);
          await tapText(tester, 'Synthetic classroom');
          expect(selected?.latitude, 12.3456);
          await tapText(tester, l10n.checkinPlaceEdit);
          await tester.enterText(
            find.byType(TextFormField).first,
            'Edited classroom',
          );
          await tapText(tester, l10n.checkinPlaceSave);
          expect(selected?.name, 'Edited classroom');
          // Remount restores saved buttons, but no position is selected for a
          // future side effect until the user chooses it again.
          await tester.pumpWidget(const SizedBox.shrink());
          selected = null;
          await tester.pumpWidget(
            app(page, language: language, brightness: brightness, scale: 2),
          );
          await settle(tester);
          expect(selected, isNull);
          await tapText(tester, 'Edited classroom');
          await tapText(tester, l10n.checkinPlaceDelete);
          expect(selected, isNull);
          expect(find.text('Edited classroom'), findsNothing);
          await tester.runAsync(() async {
            expect(await session.attendancePlaces(p), isEmpty);
          });
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets(
    'only scan passes the selected place and displays a bounded failure reason',
    (tester) async {
      final session = SessionController();
      addTearDown(session.dispose);
      final p = package();
      await tester.runAsync(() async {
        await session.installTrustedScript(p, approvedDigest: p.digest);
        await session.selectTrustedScriptSchool('synthetic');
        await session.saveAttendancePlaces(p, [
          AttendancePlace(
            id: 'synthetic',
            name: 'Synthetic classroom',
            latitude: 12.3456,
            longitude: 45.6789,
            address: 'Synthetic address',
          ),
        ]);
      });
      await tester.pumpWidget(app(MessagesPage(session: session, package: p)));
      await settle(tester);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(MessagesPage)),
      );
      await tapText(tester, 'Synthetic classroom');
      expect(session.credentialCount, 0);
      await tapText(tester, l10n.checkinScan);
      expect(find.text(l10n.checkinLocationRejected), findsOneWidget);
      expect(session.credentialCount, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('legacy check-in 1.0 never displays or receives locations', (
    tester,
  ) async {
    final session = SessionController();
    addTearDown(session.dispose);
    final p = package(schema: '1.0');
    await tester.runAsync(() async {
      await session.installTrustedScript(p, approvedDigest: p.digest);
      await session.selectTrustedScriptSchool('synthetic');
    });
    await tester.pumpWidget(app(MessagesPage(session: session, package: p)));
    await settle(tester);
    expect(find.byType(CheckinLocations), findsNothing);
    final l10n = AppLocalizations.of(tester.element(find.byType(MessagesPage)));
    await tapText(tester, l10n.checkinScan);
    expect(find.text(l10n.checkinUnsupported), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
