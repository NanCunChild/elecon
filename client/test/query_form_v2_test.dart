import 'dart:async';
import 'dart:convert';

import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/ui/home/query_form_dialog.dart';
import 'package:elecon/ui/home/query_form_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> formData(List<Map<String, dynamic>> fields) => {
  'target': 'classroom.available',
  'title': 'School query',
  'submitLabel': 'Apply conditions',
  'controls': fields,
};
QueryForm decode(List<Map<String, dynamic>> fields) =>
    queryFormFromDynamic(formData(fields), 'classroom.available')!;
Map<String, dynamic> textField(String id) => {
  'id': id,
  'kind': 'text',
  'label': id,
};
List<Map<String, dynamic>> dependentFields(
  String campus, {
  String kind = 'text',
  bool disabled = false,
}) => [
  {
    'id': 'campus',
    'kind': 'select',
    'label': 'Campus',
    'initialValue': 'A',
    'options': [
      {'value': 'A', 'label': 'Campus A'},
      {'value': 'B', 'label': 'Campus B'},
    ],
  },
  {
    'id': 'building',
    'kind': 'select',
    'label': 'Building',
    'required': true,
    'dependsOn': ['campus'],
    'initialValue': campus == 'A' ? 'old' : 'new',
    'options': [
      {
        'value': campus == 'A' ? 'old' : 'new',
        'label': campus == 'A' ? 'Old building' : 'New building',
      },
    ],
  },
  {
    'id': 'notes',
    'kind': kind,
    'label': 'Notes',
    if (disabled) ...{'disabled': true, 'disabledReason': 'Unavailable'},
  },
];

Future<void> mountForm(
  WidgetTester tester,
  QueryFormLoader load, {
  Map<String, dynamic> current = const {},
  void Function(Map<String, dynamic>?)? selected,
}) async {
  final session = SessionController();
  addTearDown(session.dispose);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final value = await showDialog<Map<String, dynamic>>(
                context: context,
                builder: (_) => QueryFormDialog(
                  load: load,
                  current: current,
                  isActive: () => true,
                  session: session,
                ),
              );
              selected?.call(value);
            },
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

Future<void> selectCampus(WidgetTester tester, String label) async {
  await tester.tap(find.byType(DropdownButtonFormField<String>).first);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.tap(find.text(label).last);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

void main() {
  test(
    'field instances keep school-owned names, false and zero; omit undeclared, disabled and optional empties',
    () {
      final form = decode([
        {...textField('roomName'), 'maxLength': 3},
        textField('roomCode'),
        {
          'id': 'minimumSeats',
          'kind': 'number',
          'label': 'Seats',
          'integer': true,
          'minimum': 0,
          'maximum': 500,
        },
        {'id': 'projector', 'kind': 'boolean', 'label': 'Projector'},
        {
          'id': 'types',
          'kind': 'multiSelect',
          'label': 'Types',
          'options': [
            {'value': 'lecture', 'label': 'Lecture'},
            {'value': 'lab', 'label': 'Lab'},
          ],
        },
        {'id': 'date', 'kind': 'date', 'label': 'Date'},
        {
          'id': 'window',
          'kind': 'timeRange',
          'label': 'Time',
          'timeZone': 'Asia/Shanghai',
        },
        {
          ...textField('configure'),
          'disabled': true,
          'disabledReason': 'Not applicable',
        },
      ]);
      final values = {
        'roomName': '😀😀😀',
        'roomCode': '',
        'minimumSeats': 0,
        'projector': false,
        'types': ['lab'],
        'date': '2026-02-28',
        'window': {'start': '08:00', 'end': '10:00'},
        'configure': 'ignored',
        'unknown': 'ignored',
      };
      expect(form.values(values), {
        'roomName': '😀😀😀',
        'minimumSeats': 0,
        'projector': false,
        'types': ['lab'],
        'date': '2026-02-28',
        'window': {'start': '08:00', 'end': '10:00'},
      });
      for (final patch in <Map<String, dynamic>>[
        {'roomName': '😀😀😀😀'},
        {'minimumSeats': -1},
        {'minimumSeats': 1.5},
        {'minimumSeats': double.infinity},
        {'projector': 'false'},
        {
          'types': ['lab', 'lab'],
        },
        {
          'types': ['unknown'],
        },
        {'date': '2026-02-30'},
        {
          'window': {'start': '23:00', 'end': '01:00'},
        },
      ]) {
        expect(form.values({...values, ...patch}), isNull);
      }
    },
  );

  test(
    'metadata rejects cycles, unknown dependencies, invalid defaults, duplicate IDs and unbounded options',
    () {
      final valid = dependentFields('A');
      expect(
        queryFormFromDynamic(formData(valid), 'classroom.available'),
        isNotNull,
      );
      final cases = <List<Map<String, dynamic>>>[
        [
          {
            ...textField('a'),
            'dependsOn': ['b'],
          },
          {
            ...textField('b'),
            'dependsOn': ['a'],
          },
        ],
        [
          {
            ...textField('a'),
            'dependsOn': ['missing'],
          },
        ],
        [textField('same'), textField('same')],
        [textField('constructor')],
        [
          {'id': 'a', 'kind': 'boolean', 'label': 'a', 'initialValue': 'false'},
        ],
        [
          {'id': 'a', 'kind': 'timeRange', 'label': 'a'},
        ],
        [
          {
            'id': 'a',
            'kind': 'number',
            'label': 'a',
            'minimum': 4,
            'maximum': 2,
          },
        ],
        [
          {
            'id': 'a',
            'kind': 'select',
            'label': 'a',
            'options': List.generate(
              201,
              (i) => {'value': '$i', 'label': '$i'},
            ),
          },
        ],
      ];
      for (final fields in cases) {
        expect(
          queryFormFromDynamic(formData(fields), 'classroom.available'),
          isNull,
        );
      }
      final graph = decode([
        textField('a'),
        {
          ...textField('b'),
          'dependsOn': ['a'],
        },
        {
          ...textField('c'),
          'dependsOn': ['b'],
        },
      ]);
      expect(graph.descendants('a'), {'b', 'c'});
    },
  );

  testWidgets(
    'dependency failure keeps drafts, blocks submit, retries and never defaults a cleared child',
    (tester) async {
      var calls = 0;
      final drafts = <Map<String, dynamic>>[];
      Map<String, dynamic>? selected;
      await mountForm(
        tester,
        (current, changed) async {
          drafts.add(
            Map<String, dynamic>.from(jsonDecode(jsonEncode(current))),
          );
          calls++;
          if (calls == 2) throw StateError('synthetic metadata failure');
          return decode(dependentFields(current['campus'] as String? ?? 'A'));
        },
        current: {'notes': 'kept'},
        selected: (value) => selected = value,
      );
      await selectCampus(tester, 'Campus B');
      await tester.pumpAndSettle();
      expect(drafts[1]['building'], isNull);
      expect(drafts[1]['notes'], 'kept');
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('query-form-submit')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('query-control-notes')),
            )
            .controller!
            .text,
        'kept',
      );
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(
        find.text('New building'),
        findsNothing,
        reason: 'Cleared child does not silently adopt a new default',
      );
      await tester.tap(find.byKey(const ValueKey('query-form-submit')));
      await tester.pump();
      expect(selected, isNull);
      expect(find.text('Enter or select a valid value'), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('New building').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('query-form-submit')));
      await tester.pumpAndSettle();
      expect(selected, {'campus': 'B', 'building': 'new', 'notes': 'kept'});
    },
  );

  testWidgets(
    'late metadata cannot overwrite a newer draft and changing field kind clears incompatible values',
    (tester) async {
      final slow = Completer<QueryForm>();
      var calls = 0;
      await mountForm(tester, (current, changed) async {
        calls++;
        if (calls == 2) return slow.future;
        return decode(
          dependentFields(
            current['campus'] as String? ?? 'A',
            kind: calls >= 3 ? 'boolean' : 'text',
          ),
        );
      }, current: {'notes': 'previous text'});
      await selectCampus(tester, 'Campus B');
      expect(calls, 2);
      await selectCampus(tester, 'Campus A');
      await tester.pumpAndSettle();
      expect(calls, 3);
      expect(find.byType(CheckboxListTile), findsOneWidget);
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isNull,
      );
      slow.complete(decode(dependentFields('B')));
      await tester.pumpAndSettle();
      expect(find.byType(CheckboxListTile), findsOneWidget);
      expect(find.text('Campus A'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'optional time range can be removed and disabled invalid numeric drafts do not block submit',
    (tester) async {
      var calls = 0;
      Map<String, dynamic>? selected;
      await mountForm(tester, (current, changed) async {
        calls++;
        return decode([
          {'id': 'enabled', 'kind': 'boolean', 'label': 'Enabled'},
          {
            'id': 'quota',
            'kind': 'number',
            'label': 'Quota',
            if (calls > 1) ...{
              'disabled': true,
              'disabledReason': 'Not applicable',
            },
          },
          {
            ...textField('dependentText'),
            'dependsOn': ['enabled'],
          },
          {
            'id': 'hours',
            'kind': 'timeRange',
            'label': 'Hours',
            'timeZone': 'Asia/Shanghai',
            'initialValue': {'start': '08:00', 'end': '09:00'},
          },
        ]);
      }, selected: (value) => selected = value);
      await tester.enterText(
        find.byKey(const ValueKey('query-control-quota')),
        'invalid',
      );
      await tester.enterText(
        find.byKey(const ValueKey('query-control-hours-start')),
        '',
      );
      await tester.enterText(
        find.byKey(const ValueKey('query-control-hours-end')),
        '',
      );
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('query-form-submit')));
      await tester.pumpAndSettle();
      expect(selected, {'enabled': false});
    },
  );
}
