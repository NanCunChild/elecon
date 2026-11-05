import 'dart:convert';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/adapter_service.dart';
import 'package:elecon/core/loader/diagnostics.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/home/capability_source.dart';
import 'package:elecon/ui/home/card_layout.dart';
import 'package:elecon/ui/home/classroom_section.dart';
import 'package:elecon/ui/home/grades_section.dart';
import 'package:elecon/ui/home/result_cards.dart';
import 'package:elecon/ui/home/schema_decode.dart';
import 'package:elecon/ui/home/script_query_controls.dart';
import 'package:elecon/ui/home/section_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'script_query_controls_test.dart' show until;

class RecordingQuerySession extends SessionController {
  final requests = <(String, bool)>[];
  @override
  Future<CapabilityRun> runCapability(
    String capability, {
    Map<String, dynamic>? params,
    bool interactive = true,
    String? htmlStdlib,
    void Function(String, String)? onLog,
    void Function(AdapterDiagnostic)? onDiagnostic,
  }) {
    requests.add((capability, interactive));
    return super.runCapability(
      capability,
      params: params,
      interactive: interactive,
      htmlStdlib: htmlStdlib,
      onLog: onLog,
      onDiagnostic: onDiagnostic,
    );
  }
}

ScriptPackage fixture() => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 17,
      'accounts': [],
      'id': 'query-form-school',
      'schoolId': 'query-form-school',
      'version': '1.0.0',
      'name': 'Synthetic form',
      'browser': false,
      'network': {'origins': []},
      'capabilities': [
        for (final entry in {
          'query.controls': '2.0',
          'classroom.available': '1.3',
          'grades.list': '1.1',
          'gpa.summary': '1.1',
        }.entries)
          {
            'id': entry.key,
            'schema': 'elecon.${entry.key}',
            'schemaVersion': entry.value,
          },
      ],
      'home': [
        for (final capability in [
          'classroom.available',
          'grades.list',
          'gpa.summary',
        ])
          {'capability': capability, 'ttlSeconds': 300, 'preload': false},
      ],
    },
    'source': '''export const capabilities={
    'query.controls':async(_,{target,current})=>({target,title:'School form',submitLabel:'Apply school query',controls:target==='grades.list'?[{id:'semester',kind:'select',label:'Semester',initialValue:'requested',options:[{value:'requested',label:'Requested semester'}]}]:[{id:'visitDate',kind:'date',label:'Visit date',initialValue:'2026-11-04',required:true},{id:'site',kind:'select',label:'Campus',initialValue:'south',options:[{value:'south',label:'South campus'}]}]}),
    'classroom.available':async(_,params)=>{
      if(Object.keys(params).join(',')!=='filters'||params.filters.visitDate!=='2026-11-04'||params.filters.site!=='south')throw new Error('wrong_filters');
      return {date:params.filters.visitDate,sourceSystem:'Synthetic eHall',appliedFilters:params.filters,coverage:{complete:false,description:'Synthetic subset'},items:[{building:'Synthetic hall',room:'Synthetic room',roomType:{code:'lab',label:'Synthetic laboratory'},teachingCapacity:80,examCapacity:40,status:'available',intervals:[{startAt:'2026-11-04T08:00:00+08:00',endAt:'2026-11-04T09:00:00+08:00',status:'available',reason:'Synthetic evidence'}]}]};
    },
    'grades.list':async(_,params)=>({term:params.filters?.semester==='requested'?'actual-term':'current-term',items:[]}),
    'gpa.summary':async(_,params)=>({gpa:params.term==='actual-term'?3.25:1.0,gradePointScale:'4.0'})
  };''',
  }),
);

Future<RecordingQuerySession> sessionFor(
  WidgetTester tester,
  ScriptPackage package,
) async => (await tester.runAsync(() async {
  final session = RecordingQuerySession();
  await session.bootstrap();
  await session.installTrustedScript(package, approvedDigest: package.digest);
  await session.selectTrustedScriptSchool(package.manifest.id);
  return session;
}))!;
Widget app(
  SessionController session,
  ScriptPackage package,
  Widget child, {
  bool bind = true,
}) {
  final page = HomeCardPresentation(
    size: HomeCardSize.expanded,
    isPage: true,
    child: child,
  );
  return SessionScope(
    controller: session,
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: bind
              ? CapabilitySourceScope(
                  source: CapabilitySource(
                    packageId: package.manifest.id,
                    digest: package.digest,
                  ),
                  child: page,
                )
              : page,
        ),
      ),
    ),
  );
}

void main() {
  test('new classroom attributes and coverage are decoded only for 1.3', () {
    final raw = {
      'items': [
        {
          'building': 'Hall',
          'room': 'Room',
          'roomType': {'label': 'Lab'},
          'teachingCapacity': 0,
          'examCapacity': 30,
          'intervals': [
            {
              'startAt': '2026-11-04T08:00:00Z',
              'endAt': '2026-11-04T09:00:00Z',
              'status': 'available',
            },
          ],
        },
      ],
      'appliedFilters': {'site': 'south'},
      'coverage': {'complete': false},
    };
    for (final version in ['1.1', '1.2', '1.3']) {
      final decoded = classroomAvailableFromDynamic(
        raw,
        schemaVersion: version,
      )!;
      expect(
        decoded.items!.single.roomType?.label,
        version == '1.3' ? 'Lab' : null,
      );
      expect(
        decoded.items!.single.teachingCapacity,
        version == '1.3' ? 0 : null,
      );
      expect(decoded.coverage?.complete, version == '1.3' ? false : null);
      expect(
        decoded.items!.single.intervals,
        version == '1.1' ? isNull : isNotEmpty,
      );
    }
  });
  testWidgets(
    'v2 classroom needs no building capability, submits filters and restores the same query with attributes',
    (tester) async {
      tester.view.physicalSize = const Size(600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final package = fixture();
      final session = await sessionFor(tester, package);
      addTearDown(session.dispose);
      Widget currentApp() =>
          app(session, package, const ClassroomSection(), bind: false);
      await tester.pumpWidget(currentApp());
      await until(
        tester,
        () => find
            .text('Synthetic laboratory · Teaching seats: 80 · Exam seats: 40')
            .evaluate()
            .isNotEmpty,
      );
      expect(find.textContaining('Synthetic subset'), findsOneWidget);
      // Applied conditions rebuild their matching editor independently of the
      // result. Metadata restoration must finish without another business call.
      await until(
        tester,
        () => find
            .byKey(const ValueKey('query-control-visitDate'))
            .evaluate()
            .isNotEmpty,
      );
      expect(
        session.requests
            .where((call) => call.$1 == 'classroom.available')
            .toList(),
        [('classroom.available', false)],
      );
      expect(
        find.byKey(const ValueKey('query-control-visitDate')),
        findsOneWidget,
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        find.byType(SectionCard),
        findsNothing,
        reason: 'The native page uses a compact toolbar above room results',
      );
      expect(find.text('Apply school query'), findsOneWidget);
      expect(find.byTooltip('Refresh'), findsOneWidget);
      expect(find.byType(FilterChip), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
      final cached = await tester.runAsync(
        () => session.cachedCapability(
          'classroom.available',
          params: {
            'filters': {'visitDate': '2026-11-04', 'site': 'south'},
          },
        ),
      );
      expect(cached, isNotNull);
      final queryCount = session.requests
          .where((call) => call.$1 == 'classroom.available')
          .length;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(currentApp());
      await until(
        tester,
        () => find
            .text('Synthetic laboratory · Teaching seats: 80 · Exam seats: 40')
            .evaluate()
            .isNotEmpty,
      );
      expect(
        session.requests
            .where((call) => call.$1 == 'classroom.available')
            .length,
        queryCount,
        reason:
            'Restored data must not be replaced by an automatic default query',
      );
      await tester.tap(find.byTooltip('Refresh').first);
      var refreshed = false;
      for (var attempt = 0; attempt < 100 && !refreshed; attempt++) {
        await tester.pump(const Duration(milliseconds: 20));
        final next = await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return session.cachedCapability(
            'classroom.available',
            params: {
              'filters': {'visitDate': '2026-11-04', 'site': 'south'},
            },
          );
        });
        refreshed = next != null && next.fetchedAt.isAfter(cached!.fetchedAt);
      }
      expect(refreshed, isTrue);
      await tester.pumpWidget(
        app(
          session,
          package,
          HomeCardPresentation(
            size: HomeCardSize.regular,
            previewHeight: 180,
            onOpen: () {},
            child: const ClassroomSection(),
          ),
        ),
      );
      await until(tester, () => find.byType(CardSummary).evaluate().isNotEmpty);
      expect(find.byType(SectionCard), findsOneWidget);
      expect(find.text('1/1'), findsOneWidget);
      expect(find.byTooltip('Refresh'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'grades submit filters while GPA follows returned term and survives cache restoration',
    (tester) async {
      final package = fixture();
      final session = await sessionFor(tester, package);
      addTearDown(session.dispose);
      Widget currentApp() =>
          app(session, package, const GradesSection(), bind: false);
      await tester.pumpWidget(currentApp());
      await until(
        tester,
        () => find.text('Apply school query').evaluate().isNotEmpty,
      );
      expect(find.byType(AlertDialog), findsNothing);
      await until(
        tester,
        () =>
            find.byType(GradesCard).evaluate().isNotEmpty &&
            tester.widget<GradesCard>(find.byType(GradesCard)).summary?.gpa ==
                3.25,
      );
      expect(
        tester.widget<GradesCard>(find.byType(GradesCard)).data.term,
        'actual-term',
      );
      expect(
        session.requests.where((call) => call.$1 == 'grades.list').toList(),
        [('grades.list', false)],
      );
      expect(
        await tester.runAsync(
          () => session.cachedCapability(
            'grades.list',
            params: {
              'filters': {'semester': 'requested'},
            },
          ),
        ),
        isNotNull,
      );
      expect(
        await tester.runAsync(
          () => session.cachedCapability(
            'gpa.summary',
            params: {'term': 'actual-term'},
          ),
        ),
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(currentApp());
      await until(
        tester,
        () =>
            find.byType(GradesCard).evaluate().isNotEmpty &&
            tester.widget<GradesCard>(find.byType(GradesCard)).summary?.gpa ==
                3.25,
      );
      expect(
        session.requests.where((call) => call.$1 == 'grades.list').length,
        1,
        reason:
            'Restoring grades must reuse the latest query without resubmission',
      );
      expect(tester.takeException(), isNull);
    },
  );
  for (final transition in ['locale', 'logout', 'update']) {
    testWidgets(
      '$transition invalidates a v2 dialog without submitting a business query',
      (tester) async {
        final package = fixture();
        final session = await sessionFor(tester, package);
        addTearDown(session.dispose);
        ScriptQuerySelection? selection;
        await tester.pumpWidget(
          app(
            session,
            package,
            Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  selection = await pickScriptQueryControls(
                    context,
                    session,
                    'classroom.available',
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await until(
          tester,
          () => find.text('School form').evaluate().isNotEmpty,
        );
        if (transition == 'locale') {
          session.scriptLocale = 'en';
        } else if (transition == 'logout') {
          session.logout();
        } else {
          final raw = jsonDecode(package.encode()) as Map<String, dynamic>;
          raw['manifest']['version'] = '1.0.1';
          final updated = ScriptPackage.parse(jsonEncode(raw));
          await tester.runAsync(
            () => session.installTrustedScript(
              updated,
              approvedDigest: updated.digest,
            ),
          );
        }
        await tester.pumpAndSettle();
        expect(selection?.params, isNull);
        expect(find.text('School form'), findsNothing);
        expect(
          await tester.runAsync(
            () => session.latestCachedCapability('classroom.available'),
          ),
          isNull,
        );
      },
    );
  }
}
