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
QueryForm decode21(List<Map<String, dynamic>> fields) => queryFormFromDynamic(
  formData(fields),
  'classroom.available',
  version: '2.1',
)!;
Map<String, dynamic> textField(String id) => {
  'id': id,
  'kind': 'text',
  'label': id,
};
List<Map<String, dynamic>> deferredFields({
  bool resolved = false,
  String option = 'lecture',
  String label = 'Lecture',
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
  textField('notes'),
  {
    'id': 'roomType',
    'kind': 'select',
    'label': 'Room type',
    'dependsOn': ['campus'],
    if (!resolved) 'deferred': true,
    'options': [
      if (resolved) {'value': option, 'label': label},
    ],
  },
];
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
  QueryFormDeferredLoader? loadDeferred,
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
                  loadDeferred: loadDeferred,
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
      await tester.ensureVisible(
        find.byKey(const ValueKey('query-control-hours-clear')),
      );
      await tester.tap(find.byKey(const ValueKey('query-control-hours-clear')));
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('query-form-submit')));
      await tester.pumpAndSettle();
      expect(selected, {'enabled': false});
    },
  );

  test('deferred metadata is versioned and restricted to optional leaves', () {
    final valid = deferredFields();
    expect(
      queryFormFromDynamic(formData(valid), 'classroom.available'),
      isNull,
    );
    expect(decode21(valid).values({'campus': 'A'}), {'campus': 'A'});
    expect(
      decode21(valid).values({'campus': 'A', 'roomType': 'lecture'}),
      isNull,
    );
    for (final fields in <List<Map<String, dynamic>>>[
      [
        ...valid.take(2),
        {...valid.last, 'required': true},
      ],
      [
        ...valid.take(2),
        {
          ...valid.last,
          'initialValue': 'lecture',
          'options': [
            {'value': 'lecture', 'label': 'Lecture'},
          ],
        },
      ],
      [
        ...valid,
        {
          ...textField('child'),
          'dependsOn': ['roomType'],
        },
      ],
    ]) {
      expect(
        queryFormFromDynamic(
          formData(fields),
          'classroom.available',
          version: '2.1',
        ),
        isNull,
      );
    }
  });

  testWidgets(
    'pending optional fields are hidden and submission cancels their load without waiting',
    (tester) async {
      final pending = Completer<QueryForm>();
      late ScriptRunCancellation cancellation;
      Map<String, dynamic>? selected;
      await mountForm(
        tester,
        (current, changed) async => decode21(deferredFields()),
        current: {'notes': 'private draft'},
        loadDeferred: (current, fields, token) {
          expect(current, {'campus': 'A'});
          expect(fields, ['roomType']);
          cancellation = token;
          return pending.future;
        },
        selected: (value) => selected = value,
      );
      expect(find.text('Room type'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(cancellation.isCancelled, isFalse);
      await tester.tap(find.byKey(const ValueKey('query-form-submit')));
      await tester.pumpAndSettle();
      expect(selected, {'campus': 'A', 'notes': 'private draft'});
      expect(cancellation.isCancelled, isTrue);
      expect(find.byType(QueryFormDialog), findsNothing);
      pending.complete(decode21(deferredFields(resolved: true)));
      await tester.pumpAndSettle();
      expect(find.byType(QueryFormDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('optional failure supports retry and still permits submission', (
    tester,
  ) async {
    var calls = 0;
    Map<String, dynamic>? selected;
    await mountForm(
      tester,
      (current, changed) async => decode21(deferredFields()),
      loadDeferred: (current, fields, cancellation) async {
        calls++;
        throw StateError('Synthetic optional request failed');
      },
      selected: (value) => selected = value,
    );
    expect(calls, 1);
    expect(find.text('Room type'), findsNothing);
    final retry = find.text('Retry optional filters (you can still query)');
    expect(retry, findsOneWidget);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(retry, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('query-form-submit')));
    await tester.pumpAndSettle();
    expect(selected, {'campus': 'A'});
  });

  testWidgets(
    'an existing unresolved selection is visible and blocks submission until explicitly cleared',
    (tester) async {
      final pending = Completer<QueryForm>();
      Map<String, dynamic>? selected;
      await mountForm(
        tester,
        (current, changed) async => decode21(deferredFields()),
        current: {'campus': 'B', 'roomType': 'lecture', 'notes': 'kept'},
        loadDeferred: (current, fields, cancellation) {
          expect(current, {'campus': 'B', 'roomType': 'lecture'});
          return pending.future;
        },
        selected: (value) => selected = value,
      );
      expect(find.text('Room type'), findsOneWidget);
      expect(find.textContaining('lecture'), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('query-form-submit')));
      await tester.pumpAndSettle();
      expect(selected, isNull);
      expect(find.byType(QueryFormDialog), findsOneWidget);
      await tester.tap(find.byTooltip('Clear condition'));
      await tester.pumpAndSettle();
      expect(find.text('Room type'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('query-form-submit')));
      await tester.pumpAndSettle();
      expect(selected, {'campus': 'B', 'notes': 'kept'});
      pending.complete(decode21(deferredFields(resolved: true)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'changing a dependency cancels the old optional request and ignores its late result',
    (tester) async {
      final pending = <Completer<QueryForm>>[];
      final cancellations = <ScriptRunCancellation>[];
      final drafts = <Map<String, dynamic>>[];
      var baseCalls = 0;
      Map<String, dynamic>? selected;
      await mountForm(
        tester,
        (current, changed) async {
          baseCalls++;
          return decode21(deferredFields());
        },
        loadDeferred: (current, fields, cancellation) {
          drafts.add(current);
          cancellations.add(cancellation);
          final next = Completer<QueryForm>();
          pending.add(next);
          return next.future;
        },
        selected: (value) => selected = value,
      );
      await selectCampus(tester, 'Campus B');
      await tester.pumpAndSettle();
      expect(baseCalls, 2);
      expect(drafts, [
        {'campus': 'A'},
        {'campus': 'B'},
      ]);
      expect(cancellations.first.isCancelled, isTrue);
      expect(cancellations.last.isCancelled, isFalse);
      pending.last.complete(
        decode21(
          deferredFields(resolved: true, option: 'lab', label: 'Campus B lab'),
        ),
      );
      await tester.pumpAndSettle();
      pending.first.complete(
        decode21(
          deferredFields(
            resolved: true,
            option: 'old',
            label: 'Campus A stale type',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>).last);
      await tester.pumpAndSettle();
      expect(find.text('Campus A stale type'), findsNothing);
      await tester.tap(find.text('Campus B lab').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('query-form-submit')));
      await tester.pumpAndSettle();
      expect(selected, {'campus': 'B', 'roomType': 'lab'});
    },
  );

  testWidgets(
    'unrelated edits do not reload optional fields or let their response replace draft and base metadata',
    (tester) async {
      final pending = Completer<QueryForm>();
      var baseCalls = 0;
      var deferredCalls = 0;
      Map<String, dynamic>? selected;
      await mountForm(
        tester,
        (current, changed) async {
          baseCalls++;
          return decode21(deferredFields());
        },
        loadDeferred: (current, fields, cancellation) {
          deferredCalls++;
          return pending.future;
        },
        selected: (value) => selected = value,
      );
      await tester.enterText(
        find.byKey(const ValueKey('query-control-notes')),
        'new draft',
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(baseCalls, 1);
      expect(deferredCalls, 1);
      final response = deferredFields(resolved: true);
      response[1] = {...textField('notes'), 'initialValue': 'stale default'};
      pending.complete(
        queryFormFromDynamic(
          {
            ...formData(response),
            'title': 'Unauthorized replacement title',
            'submitLabel': 'Unauthorized replacement submit',
          },
          'classroom.available',
          version: '2.1',
        )!,
      );
      await tester.pumpAndSettle();
      expect(find.text('School query'), findsOneWidget);
      expect(find.text('Apply conditions'), findsOneWidget);
      expect(find.text('Unauthorized replacement title'), findsNothing);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('query-control-notes')),
            )
            .controller!
            .text,
        'new draft',
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lecture').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('query-form-submit')));
      await tester.pumpAndSettle();
      expect(selected, {
        'campus': 'A',
        'notes': 'new draft',
        'roomType': 'lecture',
      });
      expect(deferredCalls, 1);
    },
  );

  testWidgets(
    'changing a dependency immediately hides resolved options while base metadata is still pending',
    (tester) async {
      final baseRefresh = Completer<QueryForm>();
      final optionalRefresh = Completer<QueryForm>();
      var baseCalls = 0;
      var optionalCalls = 0;
      await mountForm(
        tester,
        (current, changed) async {
          baseCalls++;
          return baseCalls == 1
              ? decode21(deferredFields())
              : baseRefresh.future;
        },
        loadDeferred: (current, fields, cancellation) async {
          optionalCalls++;
          return optionalCalls == 1
              ? decode21(deferredFields(resolved: true))
              : optionalRefresh.future;
        },
      );
      expect(find.byType(DropdownButtonFormField<String>), findsNWidgets(2));
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('Campus B').last);
      await tester.pump();
      expect(baseCalls, 1, reason: 'The 200 ms debounce has not elapsed');
      expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
      expect(find.text('Room type'), findsNothing);
      await tester.pump(const Duration(milliseconds: 250));
      expect(baseCalls, 2);
      expect(find.text('Room type'), findsNothing);
      baseRefresh.complete(decode21(deferredFields()));
      await tester.pumpAndSettle();
      expect(optionalCalls, 2);
      expect(find.text('Room type'), findsNothing);
      optionalRefresh.complete(
        decode21(
          deferredFields(resolved: true, option: 'lab', label: 'Campus B lab'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DropdownButtonFormField<String>), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'resolved multiselect retains invalid prior values until their chips are explicitly deleted',
    (tester) async {
      List<Map<String, dynamic>> multiFields(bool resolved) {
        final fields = deferredFields(resolved: resolved);
        fields[fields.length - 1] = {...fields.last, 'kind': 'multiSelect'};
        return fields;
      }

      Map<String, dynamic>? selected;
      await mountForm(
        tester,
        (current, changed) async => decode21(multiFields(false)),
        current: {
          'roomType': ['obsolete', 'lecture'],
        },
        loadDeferred: (current, fields, cancellation) async =>
            decode21(multiFields(true)),
        selected: (value) => selected = value,
      );
      expect(find.widgetWithText(InputChip, 'obsolete'), findsOneWidget);
      expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, 'Lecture'))
            .selected,
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('query-form-submit')));
      await tester.pumpAndSettle();
      expect(selected, isNull);
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(InputChip, 'obsolete'),
          matching: find.byIcon(Icons.close),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('obsolete'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('query-form-submit')));
      await tester.pumpAndSettle();
      expect(selected, {
        'campus': 'A',
        'roomType': ['lecture'],
      });
    },
  );

  for (final change in ['required', 'default', 'kind', 'dependency']) {
    testWidgets('rejects an optional resolution that changes $change', (
      tester,
    ) async {
      Map<String, dynamic>? selected;
      await mountForm(
        tester,
        (current, changed) async => decode21(deferredFields()),
        loadDeferred: (current, fields, cancellation) async {
          final response = deferredFields(resolved: true);
          final changed = Map<String, dynamic>.from(response.last);
          switch (change) {
            case 'required':
              changed['required'] = true;
            case 'default':
              changed['initialValue'] = 'lecture';
            case 'kind':
              changed['kind'] = 'text';
              changed.remove('options');
            case 'dependency':
              changed['dependsOn'] = ['notes'];
          }
          response[response.length - 1] = changed;
          return decode21(response);
        },
        selected: (value) => selected = value,
      );
      expect(
        find.text('Retry optional filters (you can still query)'),
        findsOneWidget,
      );
      expect(find.text('Room type'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('query-form-submit')));
      await tester.pumpAndSettle();
      expect(selected, {'campus': 'A'});
    });
  }

  testWidgets('cancelling the dialog cancels an unfinished optional request', (
    tester,
  ) async {
    final pending = Completer<QueryForm>();
    late ScriptRunCancellation cancellation;
    var closed = false;
    await mountForm(
      tester,
      (current, changed) async => decode21(deferredFields()),
      loadDeferred: (current, fields, token) {
        cancellation = token;
        return pending.future;
      },
      selected: (value) {
        expect(value, isNull);
        closed = true;
      },
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(cancellation.isCancelled, isTrue);
    pending.complete(decode21(deferredFields(resolved: true)));
    await tester.pumpAndSettle();
    expect(find.byType(QueryFormDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'disabled deferred fields never silently discard an existing condition',
    (tester) async {
      Map<String, dynamic>? selected;
      var loads = 0;
      final fields = deferredFields();
      fields[fields.length - 1] = {
        ...fields.last,
        'disabled': true,
        'disabledReason': 'Synthetic unavailable field',
      };
      final form = decode21(fields);
      expect(form.values({'campus': 'A', 'roomType': 'lecture'}), isNull);
      await mountForm(
        tester,
        (current, changed) async => form,
        current: {'roomType': 'lecture'},
        loadDeferred: (current, fields, cancellation) async {
          loads++;
          return decode21(deferredFields(resolved: true));
        },
        selected: (value) => selected = value,
      );
      expect(loads, 0);
      expect(find.textContaining('lecture'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('query-form-submit')));
      await tester.pumpAndSettle();
      expect(selected, isNull);
      expect(find.byType(QueryFormDialog), findsOneWidget);
      await tester.tap(find.byTooltip('Clear condition'));
      await tester.pumpAndSettle();
      expect(find.text('Room type'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('query-form-submit')));
      await tester.pumpAndSettle();
      expect(selected, {'campus': 'A'});
    },
  );

  testWidgets(
    'an unavailable optional resolution keeps previous choices pending with clear and retry',
    (tester) async {
      var loads = 0;
      Map<String, dynamic>? selected;
      await mountForm(
        tester,
        (current, changed) async => decode21(deferredFields()),
        current: {'roomType': 'lecture'},
        loadDeferred: (current, fields, cancellation) async {
          loads++;
          final response = deferredFields(resolved: true);
          response[response.length - 1] = {
            ...response.last,
            'disabled': true,
            'disabledReason': 'Synthetic unavailable field',
          };
          return decode21(response);
        },
        selected: (value) => selected = value,
      );
      expect(find.textContaining('lecture'), findsOneWidget);
      final retry = find.text('Retry optional filters (you can still query)');
      expect(retry, findsOneWidget);
      expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('query-form-submit')));
      await tester.pumpAndSettle();
      expect(selected, isNull);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(loads, 2);
      expect(find.textContaining('lecture'), findsOneWidget);
      await tester.tap(find.byTooltip('Clear condition'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('query-form-submit')));
      await tester.pumpAndSettle();
      expect(selected, {'campus': 'A'});
    },
  );

  testWidgets(
    'native time pickers use school defaults and support cancel and confirm',
    (tester) async {
      Map<String, dynamic>? selected;
      await mountForm(
        tester,
        (current, changed) async => decode21([
          {
            'id': 'hours',
            'kind': 'timeRange',
            'label': 'School hours',
            'timeZone': 'Asia/Shanghai',
            'initialValue': {'start': '13:17', 'end': '14:17'},
            'description': 'School time hint',
          },
        ]),
        selected: (value) => selected = value,
      );
      final start = find.byKey(const ValueKey('query-control-hours-start'));
      final end = find.byKey(const ValueKey('query-control-hours-end'));
      expect(tester.widget<TextField>(start).readOnly, isTrue);
      expect(tester.widget<TextField>(start).controller!.text, '13:17');
      expect(tester.widget<TextField>(start).decoration!.helperText, isNull);
      expect(tester.widget<TextField>(end).decoration!.helperText, isNull);
      expect(find.text('School time hint · Asia/Shanghai'), findsOneWidget);
      await tester.tap(start);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TimePickerDialog>(find.byType(TimePickerDialog))
            .initialTime,
        const TimeOfDay(hour: 13, minute: 17),
      );
      await tester.tap(
        find.descendant(
          of: find.byType(TimePickerDialog),
          matching: find.text('Cancel'),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(start).controller!.text, '13:17');
      await tester.tap(end);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TimePickerDialog>(find.byType(TimePickerDialog))
            .initialTime,
        const TimeOfDay(hour: 14, minute: 17),
      );
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(end).controller!.text, '14:17');
      await tester.tap(find.byKey(const ValueKey('query-form-submit')));
      await tester.pumpAndSettle();
      expect(selected, {
        'hours': {'start': '13:17', 'end': '14:17'},
      });
    },
  );

  for (final disabled in [false, true]) {
    testWidgets(
      'optional loading waits for a ${disabled ? 'disabled' : 'semantically invalid'} dependency',
      (tester) async {
        List<Map<String, dynamic>> fields({bool resolved = false}) => [
          {
            'id': 'seats',
            'kind': 'number',
            'label': 'Seats',
            'minimum': 10,
            'required': true,
            if (disabled) ...{
              'disabled': true,
              'disabledReason': 'Synthetic unavailable dependency',
            },
          },
          {
            'id': 'roomType',
            'kind': 'select',
            'label': 'Room type',
            'dependsOn': ['seats'],
            if (!resolved) 'deferred': true,
            'options': [
              if (resolved) {'value': 'lecture', 'label': 'Lecture'},
            ],
          },
        ];
        final drafts = <Map<String, dynamic>>[];
        await mountForm(
          tester,
          (current, changed) async => decode21(fields()),
          current: {'seats': disabled ? 15 : 5},
          loadDeferred: (current, ids, cancellation) async {
            drafts.add(current);
            expect(ids, ['roomType']);
            return decode21(fields(resolved: true));
          },
        );
        expect(drafts, isEmpty);
        expect(find.text('Room type'), findsNothing);
        final seats = find.byKey(const ValueKey('query-control-seats'));
        if (disabled) {
          expect(tester.widget<TextField>(seats).enabled, isFalse);
        } else {
          await tester.enterText(seats, '15');
          await tester.pump(const Duration(milliseconds: 250));
          await tester.pumpAndSettle();
          expect(drafts, [
            {'seats': 15},
          ]);
          expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
        }
      },
    );
  }
}
