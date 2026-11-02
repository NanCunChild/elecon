import 'package:elecon/ui/home/card_layout.dart';
// ADR-038: synthetic data through the actual cache, runtime and fixed cards.
import 'dart:async';
import 'dart:convert';

import 'package:elecon/core/adapter_service.dart';
import 'package:elecon/core/loader/diagnostics.dart';

import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/home/capability_sections.dart';
import 'package:elecon/ui/home/home_page.dart';
import 'package:elecon/ui/home/campus_snapshot_loader.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

ScriptPackage schoolPackage(
  String id, {
  String version = '1.0.0',
  String? homeTitle,
}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': homeTitle == null ? 4 : 7,
      'homeTitle': ?homeTitle,
      'id': id,
      'version': version,
      'schoolId': id,
      'name': 'Synthetic $id',
      'network': {'origins': []},
      'browser': true,
      'capabilities': [
        for (final entry in [
          ['generic.section', '1.0'],
          ['card.balance', '1.0'],
          ['schedule.week', '1.0'],
          ['notice.list', '1.1'],
          ['grades.list', '1.1'],
          ['gpa.summary', '1.1'],
          ['calendar.academic', '1.0'],
        ])
          {
            'id': entry[0],
            'schema': 'elecon.${entry[0]}',
            'schemaVersion': entry[1],
          },
      ],
      'home': [
        {
          'capability': 'card.balance',
          'params': {'scope': 'home'},
          'ttlSeconds': 3600,
          'preload': true,
        },
        {'capability': 'schedule.week', 'ttlSeconds': 3600},
        {
          'capability': 'notice.list',
          'params': {'scope': 'home'},
          'ttlSeconds': 3600,
          'preload': true,
        },
      ],
    },
    'source':
        '''export const capabilities={
    'generic.section':async(ctx,p)=>{
      await ctx.credentials.set('amount',String(p.amount ?? 1234));
      if(p.failNotices) await ctx.credentials.set('noticeFailure','true');
      return {sectionId:'login',title:'Synthetic login'};
    },
    'card.balance':async(ctx)=>{
      const amount=await ctx.credentials.get('amount');
      if(amount?.value==='fail') throw new Error('SYNTHETIC_FAILURE');
      return {balance:{amountMinor:Number(amount?.value ?? 1234),currency:'CNY'}};
    },
    'grades.list':async()=>({term:'SYNTHETIC-OLD-TERM',items:[]}),
    'gpa.summary':async()=>({gpa:3.5,gradePointScale:'4.0'}),
    'calendar.academic':async()=>({term:'SYNTHETIC-OLD-TERM',currentWeek:8}),
    'schedule.week':async(ctx,p)=>({
      term:'2026-2027-1',week:p.week ?? 8,
      teachingWeekStart:'${DateTime.now().subtract(Duration(days: DateTime.now().weekday - 1)).toIso8601String().substring(0, 10)}',
      days:[{dayOfWeek:${DateTime.now().weekday},slots:[{
        start:'1',end:'2',courseName:p.week == null ? 'Current home course' : 'Selected week course'
      }]}]
    }),
    'notice.list':async(ctx)=>{
      if((await ctx.credentials.get('noticeFailure'))?.value==='true') throw new Error('SYNTHETIC_NOTICE_FAILURE');
      const old=await ctx.credentials.get('noticeCount');
      const count=Number(old?.value ?? 0)+1;
      await ctx.credentials.set('noticeCount',String(count));
      return {items:[{id:'notice',title:'Synthetic notice '+count,category:'academic',source:'Synthetic'}]};
    }
  };''',
  }),
);

Future<SessionController> prepare(
  WidgetTester tester, {
  SessionController? controller,
}) async {
  rootBundle.clear();
  tester.view.physicalSize = const Size(1100, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final session = (await tester.runAsync(() async {
    final session = controller ?? SessionController();
    await session.bootstrap();
    for (final id in ['cache-alpha', 'cache-beta']) {
      final package = schoolPackage(id);
      await session.installTrustedScript(
        package,
        approvedDigest: package.digest,
      );
    }
    await session.selectTrustedScriptSchool('cache-alpha');
    // flutter_qjs_next retains its first host-port zone across tests. Start it
    // in runAsync before a UI callback can bind that port to a disposed fake zone.
    final warmup = await session.runTrustedScript(
      'cache-alpha',
      'calendar.academic',
    );
    expect(warmup.ok, isTrue);
    return session;
  }))!;
  addTearDown(session.dispose);
  return session;
}

Widget app(SessionController session, Widget child) => SessionScope(
  controller: session,
  child: MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: ThemeData(useMaterial3: true),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

Future<void> until(WidgetTester tester, bool Function() ready) async {
  for (var n = 0; n < 300; n++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (ready()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  fail('Synthetic cached UI did not settle');
}

Future<void> amount(
  WidgetTester tester,
  SessionController session,
  Object value,
) async {
  final run = await tester.runAsync(
    () => session.runTrustedScript(
      'cache-alpha',
      'generic.section',
      params: {'amount': value},
    ),
  );
  expect(run!.ok, isTrue);
}

// Both stages still execute through the production background QuickJS. Hold
// one successful result at the UI boundary to make invalidation deterministic.
class _DelayedResultSession extends SessionController {
  _DelayedResultSession(this.delayedCapability);
  final String delayedCapability;
  final stageReached = Completer<void>();
  final releaseStage = Completer<void>();
  final stageReturned = Completer<void>();
  int scheduleRequests = 0;

  @override
  Future<CapabilityRun> runCapability(
    String capability, {
    Map<String, dynamic>? params,
    bool interactive = true,
    String? htmlStdlib,
    void Function(String level, String message)? onLog,
    void Function(AdapterDiagnostic diagnostic)? onDiagnostic,
  }) async {
    if (capability == 'schedule.week') scheduleRequests++;
    final result = await super.runCapability(
      capability,
      params: params,
      interactive: interactive,
      htmlStdlib: htmlStdlib,
      onLog: onLog,
      onDiagnostic: onDiagnostic,
    );
    if (capability == delayedCapability && !stageReached.isCompleted) {
      expect(result.ok, isTrue);
      stageReached.complete();
      await releaseStage.future;
      stageReturned.complete();
    }
    return result;
  }
}

Future<void> refreshHomeAndPump(
  WidgetTester tester,
  SessionController session,
) async {
  // A lifecycle/timer refresh may already have continuations in FakeAsync.
  // Keep pumping those while QuickJS responds on the real event loop; awaiting
  // that existing future inside runAsync would stop the fake clock indefinitely.
  var completed = false;
  Object? failure;
  StackTrace? trace;
  session.refreshHomeData().then<void>(
    (_) {
      completed = true;
    },
    onError: (Object error, StackTrace stack) {
      failure = error;
      trace = stack;
      completed = true;
    },
  );
  await until(tester, () => completed);
  if (failure != null) Error.throwWithStackTrace(failure!, trace!);
}

void main() {
  for (final logout in [false, true]) {
    for (final grades in [false, true]) {
      testWidgets(
        '${grades ? 'grades/GPA' : 'calendar/schedule'} discards a successful old stage after ${logout ? 'logout' : 'switching schools'}',
        (tester) async {
          final session = _DelayedResultSession(
            grades ? 'gpa.summary' : 'calendar.academic',
          );
          await prepare(tester, controller: session);
          await tester.pumpWidget(
            app(
              session,
              grades
                  ? const GradesSection()
                  : const ScheduleSection(calendarEnabled: true),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            grades
                ? find.byTooltip('Refresh')
                : find.byKey(const ValueKey('schedule-refresh')),
          );
          await until(tester, () => session.stageReached.isCompleted);
          if (logout) {
            session.logout();
          } else {
            await tester.runAsync(
              () => session.selectTrustedScriptSchool('cache-beta'),
            );
          }
          await tester.pump();
          session.releaseStage.complete();
          await until(tester, () => session.stageReturned.isCompleted);
          await tester.pumpAndSettle();
          expect(find.byType(GradesCard), findsNothing);
          expect(find.byType(ScheduleCard), findsNothing);
          expect(find.textContaining('SYNTHETIC-OLD-TERM'), findsNothing);
          if (!grades) expect(session.scheduleRequests, 0);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'balance survives card destruction and refresh failures retain its timestamp',
    (tester) async {
      final session = await prepare(tester);
      await amount(tester, session, 1234);
      final initial = await tester.runAsync(
        () => session.runCapability('card.balance'),
      );
      expect(initial!.ok, isTrue);
      final before = await tester.runAsync(
        () => session.cachedCapability('card.balance'),
      );
      await tester.pumpWidget(app(session, const CardSection()));
      await until(
        tester,
        () => find.textContaining('12.34').evaluate().isNotEmpty,
      );
      expect(find.textContaining('Updated '), findsOneWidget);
      await tester.pumpWidget(app(session, const SizedBox.shrink()));
      await tester.pumpWidget(app(session, const CardSection()));
      await until(
        tester,
        () => find.textContaining('12.34').evaluate().isNotEmpty,
      );

      await amount(tester, session, 'fail');
      await tester.runAsync(() => session.refreshHomeData(force: true));
      await tester.pumpAndSettle();
      final after = await tester.runAsync(
        () => session.cachedCapability('card.balance'),
      );
      expect(after!.fetchedAt, before!.fetchedAt);
      expect(find.textContaining('12.34'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'background cache updates change visible values and switching schools clears them',
    (tester) async {
      final session = await prepare(tester);
      await amount(tester, session, 1234);
      await tester.runAsync(() => session.runCapability('card.balance'));
      await tester.pumpWidget(app(session, const CardSection()));
      await until(
        tester,
        () => find.textContaining('12.34').evaluate().isNotEmpty,
      );
      await amount(tester, session, 5678);
      await tester.runAsync(() => session.refreshHomeData(force: true));
      await until(
        tester,
        () => find.textContaining('56.78').evaluate().isNotEmpty,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      final latest = await tester.runAsync(
        () => session.latestCachedCapability('card.balance'),
      );
      expect(latest!.params, {'scope': 'home'});
      await tester.runAsync(
        () => session.selectTrustedScriptSchool('cache-beta'),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('56.78'), findsNothing);
      expect(find.textContaining('12.34'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'logout and replacing an approved digest clear current-school values',
    (tester) async {
      final session = await prepare(tester);
      await amount(tester, session, 1234);
      await tester.runAsync(() => session.runCapability('card.balance'));
      await tester.pumpWidget(app(session, const CardSection()));
      await until(
        tester,
        () => find.textContaining('12.34').evaluate().isNotEmpty,
      );
      session.logout();
      await tester.pump();
      expect(find.textContaining('12.34'), findsNothing);
      await tester.runAsync(
        () => session.selectTrustedScriptSchool('cache-alpha'),
      );
      await amount(tester, session, 5678);
      await tester.runAsync(() => session.runCapability('card.balance'));
      await until(
        tester,
        () => find.textContaining('56.78').evaluate().isNotEmpty,
      );
      final replacement = schoolPackage('cache-alpha', version: '1.0.1');
      await tester.runAsync(
        () => session.installTrustedScript(
          replacement,
          approvedDigest: replacement.digest,
        ),
      );
      await tester.pump();
      expect(find.textContaining('56.78'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'home and reopened timetable use current week while an open page can select history',
    (tester) async {
      final session = await prepare(tester);
      await tester.runAsync(() async {
        expect((await session.runCapability('schedule.week')).ok, isTrue);
        expect(
          (await session.runCapability(
            'schedule.week',
            params: {'week': 6},
          )).ok,
          isTrue,
        );
      });
      final page = ValueNotifier(false);
      addTearDown(page.dispose);
      await tester.pumpWidget(
        app(
          session,
          ValueListenableBuilder<bool>(
            valueListenable: page,
            child: const ScheduleSection(),
            builder: (_, isPage, child) => HomeCardPresentation(
              size: HomeCardSize.expanded,
              isPage: isPage,
              child: child!,
            ),
          ),
        ),
      );
      await until(
        tester,
        () => find.byType(ScheduleCard).evaluate().isNotEmpty,
      );
      expect(
        tester.widget<ScheduleCard>(find.byType(ScheduleCard)).data.week,
        8,
      );
      expect(find.text('Current home course'), findsOneWidget);
      expect(find.text('Selected week course'), findsNothing);
      page.value = true;
      await tester.pumpAndSettle();
      await until(
        tester,
        () =>
            find.byType(ScheduleCard).evaluate().isNotEmpty &&
            tester.widget<ScheduleCard>(find.byType(ScheduleCard)).data.week ==
                8,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('schedule-week-6')));
      await until(
        tester,
        () =>
            find.byType(ScheduleCard).evaluate().isNotEmpty &&
            tester.widget<ScheduleCard>(find.byType(ScheduleCard)).data.week ==
                6,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('schedule-refresh')));
      await until(
        tester,
        () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      expect(
        tester.widget<ScheduleCard>(find.byType(ScheduleCard)).data.week,
        6,
      );
      page.value = false;
      await tester.pumpAndSettle();
      await until(
        tester,
        () =>
            find.byType(ScheduleCard).evaluate().isNotEmpty &&
            tester.widget<ScheduleCard>(find.byType(ScheduleCard)).data.week ==
                8,
      );
      expect(find.text('Current home course'), findsOneWidget);
      page.value = true;
      await tester.pumpAndSettle();
      await until(
        tester,
        () =>
            find.byType(ScheduleCard).evaluate().isNotEmpty &&
            tester.widget<ScheduleCard>(find.byType(ScheduleCard)).data.week ==
                8,
      );
      expect(find.textContaining('Current home course'), findsOneWidget);
      session.logout();
      await tester.pumpAndSettle();
      expect(find.text('Current home course'), findsNothing);
      expect(find.byType(ScheduleCard), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'timetable recreates current week instead of latest historical query',
    (tester) async {
      final session = await prepare(tester);
      final result = await tester.runAsync(
        () => session.runCapability('schedule.week', params: {'week': 6}),
      );
      expect(result!.ok, isTrue);
      await tester.pumpWidget(
        app(
          session,
          const HomeCardPresentation(
            size: HomeCardSize.expanded,
            isPage: true,
            child: ScheduleSection(),
          ),
        ),
      );
      await until(
        tester,
        () => find.byType(ScheduleCard).evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      final before = await tester.runAsync(
        () => session.cachedCapability('schedule.week'),
      );
      await until(
        tester,
        () => find.textContaining('Updated ').evaluate().isNotEmpty,
      );
      expect(
        tester.widget<ScheduleCard>(find.byType(ScheduleCard)).data.week,
        8,
      );
      expect(
        find.byKey(const ValueKey('schedule-current-week-8')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('schedule-refresh')), findsOneWidget);
      expect(find.textContaining('Updated '), findsOneWidget);
      await tester.pumpWidget(app(session, const SizedBox.shrink()));
      await tester.pumpWidget(
        app(
          session,
          const HomeCardPresentation(
            size: HomeCardSize.expanded,
            isPage: true,
            child: ScheduleSection(),
          ),
        ),
      );
      await until(
        tester,
        () => find.byType(ScheduleCard).evaluate().isNotEmpty,
      );
      expect(
        tester.widget<ScheduleCard>(find.byType(ScheduleCard)).data.week,
        8,
      );
      final after = await tester.runAsync(
        () => session.cachedCapability('schedule.week'),
      );
      expect(after!.fetchedAt, before!.fetchedAt);
      expect(find.textContaining('Updated '), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'home preloads notices once and foreground resume reuses fresh cache',
    (tester) async {
      final session = await prepare(tester);
      await tester.pumpWidget(
        SessionScope(
          controller: session,
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const EleconHomePage(),
          ),
        ),
      );
      await until(
        tester,
        () => find.text('Synthetic notice 1').evaluate().isNotEmpty,
      );
      expect(find.text('Synthetic notice 2'), findsNothing);
      // A full foreground refresh interval must remain invisible and respect
      // fresh TTLs; pausing and disposal must cancel the periodic work.
      await tester.pump(const Duration(minutes: 1));
      await refreshHomeAndPump(tester, session);
      await tester.pumpAndSettle();
      expect(find.text('Synthetic notice 1'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await refreshHomeAndPump(tester, session);
      await tester.pumpAndSettle();
      expect(find.text('Synthetic notice 1'), findsOneWidget);
      expect(find.text('Synthetic notice 2'), findsNothing);
      await tester.tap(find.byIcon(Icons.refresh).first);
      await until(
        tester,
        () => find.text('Synthetic notice 2').evaluate().isNotEmpty,
      );
      session.logout();
      await tester.pump();
      expect(find.text('Synthetic notice 2'), findsNothing);
      await until(
        tester,
        () => find.text('Synthetic notice 1').evaluate().isNotEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'SDK7 header follows school and retains actual success time after failure',
    (tester) async {
      final session = await prepare(tester);
      await tester.runAsync(() async {
        final renamed = schoolPackage(
          'cache-alpha',
          version: '1.0.1',
          homeTitle: 'Synthetic campus home',
        );
        await session.installTrustedScript(
          renamed,
          approvedDigest: renamed.digest,
        );
        final candidateJson =
            jsonDecode(renamed.encode()) as Map<String, dynamic>;
        final candidateManifest =
            candidateJson['manifest'] as Map<String, dynamic>;
        candidateManifest['id'] = 'cache-alpha-enhancement';
        candidateManifest['name'] = 'Later enhancement';
        candidateManifest['homeTitle'] = 'Unselected header';
        final candidate = ScriptPackage.parse(jsonEncode(candidateJson));
        await session.installTrustedScript(
          candidate,
          approvedDigest: candidate.digest,
        );
        expect(session.selectedSchool!.adapterId, 'script:cache-alpha');
      });
      final empty = await tester.runAsync(
        () => loadCampusSnapshot(session, preferCacheOnly: true),
      );
      expect(empty!.homeTitle, 'Synthetic campus home');
      expect(empty.updatedAt, isNull);
      await tester.runAsync(() => session.refreshHomeData(force: true));
      final successful = await tester.runAsync(
        () => loadCampusSnapshot(session, preferCacheOnly: true),
      );
      expect(successful!.updatedAt, isNotNull);
      await tester.runAsync(() async {
        final result = await session.runTrustedScript(
          'cache-alpha',
          'generic.section',
          params: {'amount': 'fail', 'failNotices': true},
        );
        expect(result.ok, isTrue);
        await session.refreshHomeData(force: true);
      });
      final failed = await tester.runAsync(
        () => loadCampusSnapshot(session, preferCacheOnly: true),
      );
      expect(failed!.updatedAt, successful.updatedAt);
      expect(
        failed.notices!.items.first.title,
        successful.notices!.items.first.title,
      );
      await tester.pumpWidget(
        SessionScope(
          controller: session,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: const EleconHomePage(),
          ),
        ),
      );
      await until(
        tester,
        () => find.text('Synthetic campus home').evaluate().isNotEmpty,
      );
      expect(find.text('elecon'), findsNothing);
      final shownTime = tester
          .widget<Text>(find.byKey(const ValueKey('home-updated-at')))
          .data;
      await tester.runAsync(() => session.refreshHomeData(force: true));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('home-updated-at'))).data,
        shownTime,
      );
      await tester.runAsync(
        () => session.selectTrustedScriptSchool('cache-beta'),
      );
      await until(
        tester,
        () => find.text('Synthetic cache-beta').evaluate().isNotEmpty,
      );
      expect(find.text('Synthetic campus home'), findsNothing);
      await until(
        tester,
        () => find.text('Synthetic notice 1').evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
