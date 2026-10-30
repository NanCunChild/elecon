// Synthetic packages through the actual background QuickJS and settings UI.
import 'dart:convert';

import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/scripts/runtime.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/credential/secure_store.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/home/capability_sections.dart';
import 'package:elecon/ui/home/home_page.dart' show ScheduleCard;
import 'package:elecon/ui/scripts/script_workbench_page.dart';
import 'package:elecon/ui/scripts/script_input_presenter.dart';
import 'package:elecon/ui/settings/settings_page.dart';
import 'package:elecon/ui/theme/theme_controller.dart';
import 'package:elecon/ui/theme/theme_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

ScriptPackage package(
  String id, {
  bool login = true,
  bool slowLogin = false,
  int? currentWeek,
  bool cardAccountOnly = false,
}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 3,
      'id': id,
      'schoolId': id,
      'version': '1.0.0',
      'name': 'Synthetic school $id',
      'network': {
        'origins': ['https://school.example'],
      },
      'browser': true,
      'capabilities': [
        if (currentWeek != null)
          {
            'id': 'calendar.academic',
            'schema': 'elecon.calendar.academic',
            'schemaVersion': '1.0',
          },
        if (login)
          {
            'id': 'generic.section',
            'schema': 'elecon.generic.section',
            'schemaVersion': '1.0',
          },
        {
          'id': 'card.balance',
          'schema': 'elecon.card.balance',
          'schemaVersion': '1.0',
        },
        {
          'id': 'schedule.week',
          'schema': 'elecon.schedule.week',
          'schemaVersion': '1.0',
        },
      ],
    },
    'source':
        '''export const capabilities={
    ${currentWeek == null ? '' : '"calendar.academic":async()=>({term:"2026-2027-1",startDate:"2026-09-07",currentWeek:$currentWeek}),'}
    'generic.section':async(ctx)=>{
      ${slowLogin ? 'await new Promise(resolve=>setTimeout(resolve,1000));' : ''}
      await ctx.credentials.set('session','SYNTHETIC_$id');
      return {sectionId:'login',title:'Synthetic login'};
    },
    'card.balance':async(ctx,p)=>{
      if($cardAccountOnly) return {balance:{amountMinor:1234,currency:'CNY'}};
      const input=p.cardNumber ? {cardReference:p.cardNumber} : await ctx.ui.requestInput({title:'Card query',fields:[{id:'cardReference',label:'Campus card identifier'}]});
      if(input===null){const e=new Error('cancelled');e.code='input_cancelled';throw e;}
      return {cardNumber:input.cardReference,balance:{amountMinor:1234,currency:'CNY'}};
    },
    'schedule.week':async(ctx,p)=>{
      const input=p.studentId ? {studentId:p.studentId} : await ctx.ui.requestInput({title:'Study query',fields:[{id:'studentId',label:'Student ID'}]});
      if(input===null){const e=new Error('cancelled');e.code='input_cancelled';throw e;}
      await ctx.credentials.set('studentId',input.studentId);
      return {term:'2026-2027-1',week:p.week,days:[]};
    }
  };''',
  }),
);

Future<SessionController> prepare(
  WidgetTester tester, {
  bool login = true,
  bool slowLogin = false,
  int? currentWeek,
  bool cardAccountOnly = false,
}) async {
  rootBundle.clear();
  tester.view.physicalSize = const Size(1100, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final session = (await tester.runAsync(() async {
    final session = SessionController();
    await session.bootstrap();
    for (final id in ['alpha', 'beta']) {
      final p = package(
        id,
        login: login,
        slowLogin: slowLogin,
        currentWeek: currentWeek,
        cardAccountOnly: cardAccountOnly,
      );
      await session.installTrustedScript(p, approvedDigest: p.digest);
    }
    await session.selectTrustedScriptSchool('alpha');
    return session;
  }))!;
  addTearDown(session.dispose);
  return session;
}

Widget app(
  SessionController session,
  Widget home, {
  void Function(Future<Object?> run)? onInputRun,
}) {
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
        home: Builder(
          builder: (context) {
            session.scriptInputPresenter = (package, execute) {
              final run = presentScriptInput(
                context,
                package,
                execute,
                onCancel: session.cancelTrustedScriptRuns,
              );
              onInputRun?.call(run);
              return run;
            };
            return home;
          },
        ),
      ),
    ),
  );
}

Future<void> until(WidgetTester tester, bool Function() done) async {
  for (var n = 0; n < 300; n++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (done()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  fail('Script UI did not finish');
}

void main() {
  setUpAll(() async {
    // The pinned QuickJS host callback port retains its creation zone. Warm it
    // in the real event loop before any widget test's disposable FakeAsync.
    final p = package('warmup');
    await const TrustedScriptRuntime().run(
      package: p,
      capability: 'generic.section',
      credentials: ScriptCredentials(
        store: CredentialStore(store: InMemorySecureStore(releaseMode: false)),
        schoolId: 'warmup',
        scriptId: 'warmup',
        sdkVersion: 3,
      ),
      fetch: (_, _) async => throw StateError('warmup has no network'),
    );
  });
  testWidgets(
    'cancelling manual login closes the operation and rejects late credential writes',
    (tester) async {
      final session = await prepare(tester, slowLogin: true);
      await tester.pumpWidget(app(session, const SettingsPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign in'));
      await until(
        tester,
        () => find
            .text('Starting the selected school’s login…')
            .evaluate()
            .isNotEmpty,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1100)),
      );
      await tester.pumpAndSettle();
      expect(session.credentialCount, 0);
      expect(find.text('Sign in'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'settings login executes the selected script instead of opening the workbench',
    (tester) async {
      final session = await prepare(tester);
      await tester.pumpWidget(app(session, const SettingsPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign in'));
      await until(
        tester,
        () =>
            session.isLoggedIn &&
            find.text('Sign in again').evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      expect(find.byType(ScriptWorkbenchPage), findsNothing);
      expect(session.credentialCount, 1);
      await tester.runAsync(() => session.selectTrustedScriptSchool('beta'));
      expect(session.credentialCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing manual entry reports unavailable without running another script',
    (tester) async {
      final session = await prepare(tester, login: false);
      await tester.pumpWidget(app(session, const SettingsPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign in'));
      await until(
        tester,
        () => find
            .textContaining('does not provide a manual login entry')
            .evaluate()
            .isNotEmpty,
      );
      expect(session.credentialCount, 0);
      expect(find.byType(ScriptWorkbenchPage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'account balance without card number never prompts for a fabricated id',
    (tester) async {
      final session = await prepare(tester, cardAccountOnly: true);
      await tester.pumpWidget(
        app(session, const Scaffold(body: CardSection())),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看余额'));
      await until(
        tester,
        () => find.text('Campus card account').evaluate().isNotEmpty,
      );
      expect(find.textContaining('12.34'), findsOneWidget);
      expect(find.text('School script requests information'), findsNothing);
      expect(find.byType(TextFormField), findsNothing);
      expect(session.credentialCount, 0);
    },
  );

  testWidgets(
    'missing card number prompts once and resumes balance query with user input',
    (tester) async {
      final session = await prepare(tester);
      await tester.pumpWidget(
        app(session, const Scaffold(body: CardSection())),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看余额'));
      await until(
        tester,
        () => find
            .text('School script requests information')
            .evaluate()
            .isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextFormField), 'CARD-SYNTHETIC-001');
      await tester.tap(find.text('Submit and continue'));
      await until(
        tester,
        () => find.textContaining('12.34').evaluate().isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('CARD-SYNTHETIC-001'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'SSO without a student id can resume the week query after explicit input',
    (tester) async {
      final session = await prepare(tester);
      await tester.pumpWidget(
        app(session, const Scaffold(body: ScheduleSection())),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('View week 1'));
      await until(
        tester,
        () => find
            .text('School script requests information')
            .evaluate()
            .isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextFormField), 'SYNTHETIC-STUDENT');
      await tester.tap(find.text('Submit and continue'));
      await until(
        tester,
        () => find.textContaining('2026-2027-1').evaluate().isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('SYNTHETIC-STUDENT'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'calendar-enabled timetable queries the current week only after user action',
    (tester) async {
      final session = await prepare(tester, currentWeek: 8);
      await tester.pumpWidget(
        app(
          session,
          const Scaffold(body: ScheduleSection(calendarEnabled: true)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('View this week'), findsOneWidget);
      expect(find.byType(ScheduleCard), findsNothing);
      expect(session.credentialCount, 0);
      await tester.tap(find.text('View this week'));
      await until(
        tester,
        () => find
            .text('School script requests information')
            .evaluate()
            .isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextFormField), 'SYNTHETIC-STUDENT');
      await tester.tap(find.text('Submit and continue'));
      await until(
        tester,
        () => find.byType(ScheduleCard).evaluate().isNotEmpty,
      );
      expect(
        tester.widget<ScheduleCard>(find.byType(ScheduleCard)).data.week,
        8,
      );
      expect(find.text('View this week'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manual week selection is not replaced by the calendar current week',
    (tester) async {
      final session = await prepare(tester, currentWeek: 8);
      await tester.pumpWidget(
        app(
          session,
          const Scaffold(body: ScheduleSection(calendarEnabled: true)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose a week'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('View week 1'));
      await until(
        tester,
        () => find
            .text('School script requests information')
            .evaluate()
            .isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextFormField), 'SYNTHETIC-STUDENT');
      await tester.tap(find.text('Submit and continue'));
      await until(
        tester,
        () => find.byType(ScheduleCard).evaluate().isNotEmpty,
      );
      expect(find.text('View week 1'), findsOneWidget);
      expect(find.text('View week 8'), findsNothing);
    },
  );

  testWidgets(
    'switching schools while input is open cannot replay the old query',
    (tester) async {
      final session = await prepare(tester);
      var inputCompleted = false;
      Object? inputFailure;
      await tester.pumpWidget(
        app(
          session,
          const Scaffold(body: CardSection()),
          onInputRun: (run) {
            run.then<void>(
              (_) {
                inputCompleted = true;
              },
              onError: (Object error) {
                inputFailure = error;
                inputCompleted = true;
              },
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看余额'));
      await until(
        tester,
        () => find
            .text('School script requests information')
            .evaluate()
            .isNotEmpty,
      );
      await tester.runAsync(() => session.selectTrustedScriptSchool('beta'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextFormField), 'CARD-SYNTHETIC-OLD');
      await tester.tap(find.text('Submit and continue'));
      await tester.pumpAndSettle();
      // QuickJS closes in a real isolate. Frame settlement alone does not
      // await its close acknowledgement or the native-input invocation.
      await until(tester, () => inputCompleted);
      expect(
        inputFailure,
        isA<ScriptRunException>().having(
          (error) => error.code,
          'code',
          'invocation_cancelled',
        ),
      );
      expect(find.text('School script requests information'), findsNothing);
      expect(find.textContaining('12.34'), findsNothing);
      expect(session.credentialCount, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
