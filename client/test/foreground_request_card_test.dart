import 'dart:async';
import 'dart:convert';

import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/debug/dev_log.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/community/checkin_locations.dart';
import 'package:elecon/ui/home/card_layout.dart';
import 'package:elecon/ui/home/checkin_section.dart';
import 'package:elecon/ui/home/foreground_request_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ScriptPackage package({String version = '1.1'}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 9,
      'id': 'synthetic-checkin',
      'schoolId': 'synthetic-checkin',
      'version': '1.0.0',
      'name': 'Synthetic attendance',
      'network': {'origins': []},
      'browser': false,
      'scanner': true,
      'capabilities': [
        {
          'id': 'messages.session',
          'schema': 'elecon.messages.session',
          'schemaVersion': '1.0',
        },
        {
          'id': 'attendance.checkin',
          'schema': 'elecon.attendance.checkin',
          'schemaVersion': version,
        },
      ],
    },
    'source': '''export const capabilities={
    'messages.session':async(ctx,p)=>{
      if(p.operation!=='login') throw new Error('unexpected automatic account request');
      await ctx.credentials.set('account','synthetic');
      return {serviceId:'synthetic',serviceName:'Synthetic',status:'authenticated',accountId:'synthetic',accountLabel:'Test account'};
    },
    'attendance.checkin':async(ctx,p)=>{
      ctx.log('info','probe/1 stage=1 event=ok http=200 ms=12 flags=00000000');
      ctx.log('info','probe/1 stage=1 event=ok http=200 ms=12 flags=00000000 SECRET');
      const scan=await ctx.ui.scanQRCode();
      if(!scan) return {status:'cancelled'};
      await ctx.credentials.set('submitted',p.location?.address ?? 'no-location');
      return {status:'confirmed'};
    }
  };''',
  }),
);

Widget app(
  SessionController session, {
  bool page = true,
  GlobalKey<NavigatorState>? navigator,
}) => SessionScope(
  controller: session,
  child: MaterialApp(
    navigatorKey: navigator,
    locale: const Locale('en'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: Scaffold(
      body: SingleChildScrollView(
        child: HomeCardPresentation(
          size: HomeCardSize.expanded,
          isPage: page,
          child: const CheckinSection(),
        ),
      ),
    ),
  ),
);

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 150; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}

Future<SessionController> install(
  WidgetTester tester, {
  String version = '1.1',
}) async {
  final session = SessionController();
  addTearDown(session.dispose);
  final p = package(version: version);
  await tester.runAsync(() async {
    await session.installTrustedScript(p, approvedDigest: p.digest);
    await session.selectTrustedScriptSchool('synthetic-checkin');
  });
  return session;
}

Future<void> tap(WidgetTester tester, String text) async {
  final finder = find.text(text).last;
  await tester.ensureVisible(finder);
  await tester.runAsync(() => tester.tap(finder));
  await tester.pump();
}

void main() {
  setUp(() => DevLog.instance.clear());
  tearDown(() => DevLog.instance.clear());
  testWidgets('home preview and opened page never preload; login is explicit', (
    tester,
  ) async {
    final session = await install(tester);
    var scans = 0;
    session.scriptScannerPresenter = (_, _) async {
      scans++;
      return const {'text': 'synthetic-ticket', 'format': 'qrCode'};
    };
    await tester.pumpWidget(app(session, page: false));
    await settle(tester);
    expect(find.byType(ForegroundRequestSection), findsNothing);
    expect(session.credentialCount, 0);
    expect(scans, 0);
    await tester.pumpWidget(app(session));
    await settle(tester);
    expect(session.credentialCount, 0);
    expect(scans, 0);
    final l10n = AppLocalizations.of(
      tester.element(find.byType(CheckinSection)),
    );
    await tap(tester, l10n.communityConnect);
    await settle(tester);
    expect(find.text('Synthetic · Test account'), findsOneWidget);
    expect(session.credentialCount, 1);
    expect(scans, 0);
    await tap(tester, l10n.checkinStart);
    await settle(tester);
    expect(scans, 1);
    final probes = DevLog.instance.visible(only: DevLogCategory.probe);
    expect(probes, hasLength(1));
    expect(
      probes.single.message,
      'probe/1 stage=1 event=ok http=200 ms=12 flags=00000000',
    );
    expect(
      DevLog.instance.entries.map((entry) => entry.message).join('\n'),
      isNot(contains('SECRET')),
    );
    expect(session.credentialCount, 2);
    expect(find.text(l10n.checkinConfirmed), findsOneWidget);
    expect(
      await tester.runAsync(
        () => session.latestCachedCapability('attendance.checkin'),
      ),
      isNull,
    );
  });

  testWidgets('scanner child route does not cancel parent request', (
    tester,
  ) async {
    final session = await install(tester);
    final nav = GlobalKey<NavigatorState>();
    var scans = 0;
    session.scriptScannerPresenter = (_, _) async {
      scans++;
      return nav.currentState!.push<Map<String, dynamic>>(
        MaterialPageRoute(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(
                context,
              ).pop({'text': 'synthetic', 'format': 'qrCode'}),
              child: const Text('Return synthetic scan'),
            ),
          ),
        ),
      );
    };
    await tester.pumpWidget(app(session, navigator: nav));
    await settle(tester);
    final l10n = AppLocalizations.of(
      tester.element(find.byType(CheckinSection)),
    );
    await tap(tester, l10n.checkinStart);
    for (var i = 0; i < 50 && scans == 0; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pump(const Duration(seconds: 1));
    expect(scans, 1);
    await tap(tester, 'Return synthetic scan');
    await settle(tester);
    expect(find.text(l10n.checkinConfirmed), findsOneWidget);
    expect(session.credentialCount, 1);
  });

  testWidgets(
    'busy guard and background revoke a waiting scan before late submission',
    (tester) async {
      final session = await install(tester);
      final scan = Completer<Map<String, dynamic>?>();
      var scans = 0;
      session.scriptScannerPresenter = (_, _) {
        scans++;
        return scan.future;
      };
      await tester.pumpWidget(app(session));
      await settle(tester);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(CheckinSection)),
      );
      await tap(tester, l10n.checkinStart);
      for (var i = 0; i < 50 && scans == 0; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(scans, 1);
      final logButton = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (widget) =>
              widget is IconButton && widget.tooltip == l10n.devLogTitle,
        ),
      );
      expect(logButton.onPressed, isNull);
      await tap(tester, l10n.checkinStart);
      expect(scans, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      scan.complete({'text': 'synthetic', 'format': 'qrCode'});
      await settle(tester);
      expect(session.credentialCount, 0);
      expect(find.text(l10n.checkinConfirmed), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    },
  );

  for (final exit in ['route', 'provider']) {
    testWidgets('$exit invalidation revokes late scanner results', (
      tester,
    ) async {
      final session = await install(tester);
      final nav = GlobalKey<NavigatorState>();
      final scan = Completer<Map<String, dynamic>?>();
      var scans = 0;
      session.scriptScannerPresenter = (_, _) {
        scans++;
        return scan.future;
      };
      await tester.pumpWidget(app(session, page: false, navigator: nav));
      await settle(tester);
      unawaited(
        nav.currentState!.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(
              body: SingleChildScrollView(
                child: HomeCardPresentation(
                  size: HomeCardSize.expanded,
                  isPage: true,
                  child: CheckinSection(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await settle(tester);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(ForegroundRequestSection)),
      );
      await tap(tester, l10n.checkinStart);
      for (var i = 0; i < 50 && scans == 0; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(scans, 1);
      if (exit == 'route') {
        nav.currentState!.pop();
        await tester.pump();
      } else {
        await tester.runAsync(
          () => session.enableTrustedScript('synthetic-checkin', false),
        );
        await tester.pump();
      }
      scan.complete({'text': 'synthetic', 'format': 'qrCode'});
      await settle(tester);
      expect(session.credentialCount, 0);
      expect(find.text(l10n.checkinConfirmed), findsNothing);
    });
  }

  testWidgets('old attendance schema has no location controls', (tester) async {
    final session = await install(tester, version: '1.0');
    await tester.pumpWidget(app(session));
    await settle(tester);
    expect(find.byType(CheckinLocations), findsNothing);
    expect(session.credentialCount, 0);
  });
}
