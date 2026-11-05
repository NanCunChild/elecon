import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/ui/home/query_form_dialog.dart';
import 'package:elecon/ui/home/query_form_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

QueryForm form({
  bool resolved = false,
  List<Map<String, dynamic>> extra = const [],
}) => queryFormFromDynamic(
  {
    'target': 'classroom.available',
    'title': 'School form',
    'submitLabel': 'Apply',
    'controls': [
      {
        'id': 'date',
        'kind': 'date',
        'label': 'Date',
        'required': true,
        'initialValue': '2026-11-05',
      },
      {
        'id': 'note',
        'kind': 'text',
        'label': 'Note',
        'initialValue': 'school default',
      },
      {
        'id': 'type',
        'kind': 'select',
        'label': 'Room type',
        'dependsOn': ['date'],
        if (!resolved) 'deferred': true,
        'options': [
          if (resolved) {'value': 'lab', 'label': 'Laboratory'},
        ],
      },
      ...extra,
    ],
  },
  'classroom.available',
  version: '2.1',
)!;

Future<void> mount(
  WidgetTester tester, {
  Map<String, dynamic>? restored,
  Map<String, dynamic> current = const {},
  void Function(Map<String, dynamic>)? initial,
  Future<bool> Function(Map<String, dynamic>?)? save,
  void Function()? deferred,
  QueryFormLoader? load,
  void Function(Map<String, dynamic>)? submit,
}) async {
  final session = SessionController();
  addTearDown(session.dispose);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: QueryFormDialog(
            session: session,
            isActive: () => true,
            current: current,
            collapseOptional: true,
            submitInitial: true,
            load: load ?? (_, _) async => form(),
            loadDraft: () async => restored,
            saveDraft: save,
            onSubmit: submit ?? (_) {},
            onInitialSubmit: initial,
            loadDeferred: (_, _, _) async {
              deferred?.call();
              return form(resolved: true);
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('mismatched applied values discard a former draft', (
    tester,
  ) async {
    final initial = <Map<String, dynamic>>[];
    await mount(
      tester,
      current: const {'date': '2026-11-08'},
      initial: initial.add,
      restored: {
        'applied': {'date': '2026-11-07'},
        'edits': {'note': 'old base draft'},
        'cleared': <String>[],
      },
    );
    expect(initial.single['date'], '2026-11-08');
    expect(initial.single['note'], 'school default');
    expect(find.textContaining('old base draft'), findsNothing);
  });

  testWidgets('explicit false remains visible among collapsed conditions', (
    tester,
  ) async {
    await mount(
      tester,
      load: (_, _) async => form(
        extra: [
          {
            'id': 'projector',
            'kind': 'boolean',
            'label': 'Projector',
            'initialValue': false,
          },
        ],
      ),
    );
    expect(find.text('More conditions (2)'), findsOneWidget);
    expect(find.textContaining('Projector:'), findsOneWidget);
  });

  testWidgets(
    'unfinished numeric and time inputs survive leaving without submitting',
    (tester) async {
      final metadata = form(
        extra: [
          {
            'id': 'seats',
            'kind': 'number',
            'label': 'Seats',
            'initialValue': 7,
          },
          {
            'id': 'hours',
            'kind': 'timeRange',
            'label': 'Hours',
            'timeZone': 'Asia/Shanghai',
            'initialValue': {'start': '08:00', 'end': '09:00'},
          },
        ],
      );
      Map<String, dynamic>? saved;
      final metadataInputs = <Map<String, dynamic>>[];
      final submitted = <Map<String, dynamic>>[];
      Future<QueryForm> load(Map<String, dynamic> draft, String? _) async {
        metadataInputs.add(draft);
        return metadata;
      }

      Future<bool> save(Map<String, dynamic>? draft) async {
        saved = draft;
        return true;
      }

      await mount(tester, load: load, save: save);
      await tester.tap(find.byKey(const ValueKey('query-form-optional')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('query-control-seats')),
        '-',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('query-control-hours-clear')),
      );
      await tester.tap(find.byKey(const ValueKey('query-control-hours-clear')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('query-control-hours-start')),
      );
      await tester.tap(find.byKey(const ValueKey('query-control-hours-start')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      final selectedStart = tester
          .widget<TextField>(
            find.byKey(const ValueKey('query-control-hours-start')),
          )
          .controller!
          .text;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(saved!['rawEditors'], {
        'seats': '-',
        'range:hours:start': selectedStart,
        'range:hours:end': '',
      });
      final initial = <Map<String, dynamic>>[];
      await mount(
        tester,
        load: load,
        save: save,
        restored: saved,
        submit: submitted.add,
        initial: initial.add,
      );
      expect(initial, isEmpty);
      expect(metadataInputs.last.containsKey('seats'), isFalse);
      expect(metadataInputs.last.containsKey('hours'), isFalse);
      await tester.tap(find.byKey(const ValueKey('query-form-optional')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('query-control-seats')),
            )
            .controller!
            .text,
        '-',
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('query-control-hours-start')),
            )
            .controller!
            .text,
        selectedStart,
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('query-control-hours-end')),
            )
            .controller!
            .text,
        '',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('query-form-submit')),
      );
      await tester.tap(find.byKey(const ValueKey('query-form-submit')));
      await tester.pumpAndSettle();
      expect(submitted, isEmpty);
      await tester.ensureVisible(
        find.byKey(const ValueKey('query-control-seats')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('query-control-seats')),
        '3',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('query-form-submit')),
      );
      await tester.tap(find.byKey(const ValueKey('query-form-submit')));
      await tester.pumpAndSettle();
      expect(
        submitted,
        isEmpty,
        reason: 'an incomplete time range is still invalid',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('query-control-hours-clear')),
      );
      await tester.tap(find.byKey(const ValueKey('query-control-hours-clear')));
      await tester.ensureVisible(
        find.byKey(const ValueKey('query-form-submit')),
      );
      await tester.tap(find.byKey(const ValueKey('query-form-submit')));
      await tester.pumpAndSettle();
      expect(submitted.single['seats'], 3);
      expect(submitted.single.containsKey('hours'), isFalse);
      expect(submitted.single.containsKey('rawEditors'), isFalse);
    },
  );

  testWidgets(
    'folded options do not load until expanded; required inputs stay visible',
    (tester) async {
      var loads = 0;
      await mount(tester, deferred: () => loads++);
      expect(find.byKey(const ValueKey('query-control-date')), findsOneWidget);
      expect(find.byKey(const ValueKey('query-control-note')), findsNothing);
      expect(loads, 0);
      expect(find.text('More conditions (1)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('query-form-optional')));
      await tester.pumpAndSettle();
      expect(loads, 1);
      expect(find.byKey(const ValueKey('query-control-note')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('query-form-optional')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('query-form-optional')));
      await tester.pumpAndSettle();
      expect(
        loads,
        1,
        reason: 'already resolved dependency options are reused',
      );
    },
  );

  testWidgets(
    'restored edits and clears cannot auto-submit or reintroduce defaults',
    (tester) async {
      final initial = <Map<String, dynamic>>[];
      final saved = <Map<String, dynamic>?>[];
      await mount(
        tester,
        initial: initial.add,
        restored: {
          'applied': <String, dynamic>{},
          'edits': {'date': '2026-11-07'},
          'cleared': ['note'],
        },
        save: (draft) async {
          saved.add(draft);
          return true;
        },
      );
      expect(initial, isEmpty);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('query-control-date')))
            .controller!
            .text,
        '2026-11-07',
      );
      expect(find.text('More conditions (0)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('query-form-optional')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('query-control-note')))
            .controller!
            .text,
        '',
      );
      await tester.enterText(
        find.byKey(const ValueKey('query-control-note')),
        'my draft',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(saved.last!['edits'], {'date': '2026-11-07', 'note': 'my draft'});
      expect(initial, isEmpty);
      await tester.tap(find.byKey(const ValueKey('query-form-submit')));
      await tester.pumpAndSettle();
      expect(
        saved.last,
        isNull,
        reason: 'submission clears the uncommitted draft',
      );
    },
  );

  testWidgets(
    'existing optional selections are verified even while collapsed',
    (tester) async {
      var loads = 0;
      await mount(
        tester,
        current: const {'date': '2026-11-05', 'type': 'lab'},
        deferred: () => loads++,
      );
      expect(loads, 1);
      expect(find.textContaining('Laboratory'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('query-form-submit')),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets(
    'draft storage failure leaves the current edits usable and visible',
    (tester) async {
      await mount(tester, save: (_) async => false);
      await tester.tap(find.byKey(const ValueKey('query-form-optional')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('query-control-note')),
        'unsaved draft',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Changes are kept for this visit; the draft could not be saved.',
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('query-control-note')))
            .controller!
            .text,
        'unsaved draft',
      );
    },
  );
}
