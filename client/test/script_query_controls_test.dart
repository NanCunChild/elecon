import 'dart:convert';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/home/script_query_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> description(String target) => {
  'target': target,
  'title': 'School conditions',
  'submitLabel': 'Apply school filters',
  'controls': target == 'grades.list'
      ? [
          {
            'id': 'term',
            'kind': 'select',
            'parameter': 'term',
            'label': 'Academic semester',
            'initialValue': 'A',
            'options': [
              {'value': 'A', 'label': 'Alpha term'},
              {'value': 'B', 'label': 'Beta term'},
            ],
          },
        ]
      : [
          {'id': 'date', 'kind': 'date', 'parameter': 'date', 'label': 'Date'},
          {'id': 'room', 'kind': 'text', 'parameter': 'room', 'label': 'Room'},
          {
            'id': 'time',
            'kind': 'timeRange',
            'parameter': 'start',
            'label': 'School local time',
          },
        ],
};

ScriptPackage package(
  String id, {
  required bool target,
  required String title,
}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 4,
      'id': id,
      'version': '1.0.0',
      'schoolId': 'query-school',
      'name': id,
      'browser': false,
      'network': {'origins': []},
      'capabilities': [
        {
          'id': 'query.controls',
          'schema': 'elecon.query.controls',
          'schemaVersion': '1.0',
        },
        if (target)
          {
            'id': 'grades.list',
            'schema': 'elecon.grades.list',
            'schemaVersion': '1.1',
          },
      ],
    },
    'source':
        '''export const capabilities={
    'grades.list':async()=>({term:'A',items:[]}),
    'query.controls':async(_,{target})=>(${jsonEncode({...description('grades.list'), 'title': title})})
  };''',
  }),
);
Future<void> until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 200; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (ready()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  fail('Control dialog did not settle');
}

void main() {
  testWidgets(
    'inline defaults stay bound to the business provider and submit only once',
    (tester) async {
      ScriptPackage formPackage(String id, bool target, String label) {
        final raw =
            jsonDecode(package(id, target: target, title: label).encode())
                as Map<String, dynamic>;
        raw['manifest']['sdkVersion'] = 17;
        raw['manifest']['accounts'] = [];
        raw['manifest']['capabilities'][0]['schemaVersion'] = '2.0';
        raw['source'] =
            '''export const capabilities={
        'grades.list':async()=>({items:[]}),
        'query.controls':async()=>({target:'grades.list',title:'Form',submitLabel:'Submit',controls:[{id:'term',kind:'text',label:'$label',initialValue:'A'}]})
      };''';
        return ScriptPackage.parse(jsonEncode(raw));
      }

      final session = (await tester.runAsync(() async {
        final session = SessionController();
        await session.bootstrap();
        for (final p in [
          formPackage('target-source', true, 'Correct provider'),
          formPackage('other-source', false, 'Wrong provider'),
        ]) {
          await session.installTrustedScript(p, approvedDigest: p.digest);
        }
        await session.selectTrustedScriptSchool('target-source');
        await session.selectTrustedScriptProvider(
          'query-school',
          'query.controls',
          'other-source',
        );
        return session;
      }))!;
      addTearDown(session.dispose);
      final initial = <Map<String, dynamic>>[];
      final manual = <Map<String, dynamic>>[];
      await tester.pumpWidget(
        SessionScope(
          controller: session,
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: InlineScriptQueryControls(
                target: 'grades.list',
                current: const {},
                onSubmit: manual.add,
                onInitialSubmit: initial.add,
                submitInitial: true,
                fallback: const Text('Unavailable'),
              ),
            ),
          ),
        ),
      );
      await until(tester, () => initial.isNotEmpty);
      expect(initial, [
        {
          'filters': {'term': 'A'},
        },
      ]);
      expect(manual, isEmpty);
      await tester.tap(find.byKey(const ValueKey('query-form-optional')));
      await tester.pumpAndSettle();
      expect(find.text('Correct provider'), findsOneWidget);
      expect(find.text('Wrong provider'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('query-control-term')),
        'B',
      );
      await tester.pumpAndSettle();
      expect(initial.length, 1);
      expect(manual, isEmpty);
      await tester.tap(find.text('Submit'));
      expect(manual, [
        {
          'filters': {'term': 'B'},
        },
      ]);
    },
  );
  test(
    'metadata rejects unsupported bindings, duplicate parameters and ambiguous defaults',
    () {
      expect(
        queryControlsFromDynamic(description('grades.list'), 'grades.list'),
        isNotNull,
      );
      final cases = <Map<String, Object?>>[
        {...description('grades.list'), 'target': 'climate.command'},
        {
          ...description('grades.list'),
          'controls': [
            {
              'id': 'term',
              'kind': 'text',
              'parameter': 'term',
              'label': 'Term',
            },
          ],
        },
        {
          ...description('classroom.available'),
          'controls': [
            {'id': 'a', 'kind': 'text', 'parameter': 'room', 'label': 'One'},
            {'id': 'b', 'kind': 'text', 'parameter': 'room', 'label': 'Two'},
          ],
        },
        {
          ...description('classroom.available'),
          'controls': [
            {
              'id': 'time',
              'kind': 'timeRange',
              'parameter': 'start',
              'label': 'Time',
              'initialValue': '23:00',
              'initialEnd': '01:00',
            },
          ],
        },
        {
          ...description('classroom.available'),
          'controls': [
            {
              'id': 'date',
              'kind': 'date',
              'parameter': 'date',
              'label': 'Date',
              'initialValue': '2026-02-30',
            },
          ],
        },
      ];
      for (final raw in cases) {
        expect(
          queryControlsFromDynamic(
            raw,
            raw['target'] == 'classroom.available'
                ? 'classroom.available'
                : 'grades.list',
          ),
          isNull,
        );
      }
    },
  );
  test(
    'selected values are bounded and only emit declared standard parameters',
    () {
      final controls = queryControlsFromDynamic(
        description('classroom.available'),
        'classroom.available',
      )!;
      expect(
        queryControlValues(controls, {
          'date': '2026-02-28',
          'room': 'A',
          'start': '09:00',
          'end': '10:00',
          'evil': 'ignored',
        }),
        {'date': '2026-02-28', 'room': 'A', 'start': '09:00', 'end': '10:00'},
      );
      expect(queryControlValues(controls, {'start': '09:00'}), isNull);
      expect(
        queryControlValues(controls, {'start': '23:00', 'end': '01:00'}),
        isNull,
      );
      expect(
        queryControlValues(controls, {'start': '12:60', 'end': '13:00'}),
        isNull,
      );
      expect(queryControlValues(controls, {'date': '2026-02-30'}), isNull);
      expect(queryControlValues(controls, {'date': '0000-01-01'}), isNull);
      expect(queryControlValues(controls, {'room': 'x' * 129}), isNull);
      expect(queryControlValues(controls, {}), isNull);
      expect(queryControlValues(controls, {'date': '2026-02-28'}), {
        'date': '2026-02-28',
      });
      final grades = queryControlsFromDynamic(
        description('grades.list'),
        'grades.list',
      )!;
      expect(queryControlValues(grades, {'term': 'not-declared'}), isNull);
      expect(queryControlValues(grades, {'term': 'B'}), {'term': 'B'});
    },
  );
  testWidgets(
    'controls come from the target provider and submit selected values only after press',
    (tester) async {
      final session = (await tester.runAsync(() async {
        final s = SessionController();
        await s.bootstrap();
        for (final p in [
          package(
            'target-source',
            target: true,
            title: 'Target source controls',
          ),
          package('other-source', target: false, title: 'Wrong provider'),
        ]) {
          await s.installTrustedScript(p, approvedDigest: p.digest);
        }
        await s.selectTrustedScriptSchool('target-source');
        await s.selectTrustedScriptProvider(
          'query-school',
          'query.controls',
          'other-source',
        );
        return s;
      }))!;
      addTearDown(session.dispose);
      ScriptQuerySelection? selection;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  selection = await pickScriptQueryControls(
                    context,
                    session,
                    'grades.list',
                    current: {'term': 'A'},
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await until(
        tester,
        () => find.text('Target source controls').evaluate().isNotEmpty,
      );
      expect(find.text('Wrong provider'), findsNothing);
      expect(selection, isNull);
      await tester.tap(find.byKey(const ValueKey('query-control-term')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Beta term').last);
      await tester.pumpAndSettle();
      expect(selection, isNull);
      await tester.tap(find.text('Apply school filters'));
      await tester.pumpAndSettle();
      expect(selection?.params, {'term': 'B'});

      selection = null;
      await tester.tap(find.text('Open'));
      await until(
        tester,
        () => find.text('Target source controls').evaluate().isNotEmpty,
      );
      session.logout();
      await tester.tap(find.text('Apply school filters'));
      await tester.pumpAndSettle();
      expect(
        selection?.params,
        isNull,
        reason: 'Identity changes discard late selections',
      );
    },
  );
}
