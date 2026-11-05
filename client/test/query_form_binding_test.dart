import 'dart:convert';

import 'package:elecon/core/debug/dev_log.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/home/script_query_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'script_query_controls_test.dart' show until;

ScriptPackage package({bool wait = false}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 17,
      'accounts': [],
      'id': 'form-binding-synthetic',
      'schoolId': 'form-binding-synthetic',
      'version': '1.0.0',
      'name': 'Synthetic forms',
      'network': {'origins': []},
      'browser': false,
      'capabilities': [
        {
          'id': 'query.controls',
          'schema': 'elecon.query.controls',
          'schemaVersion': '2.1',
        },
        {
          'id': 'grades.list',
          'schema': 'elecon.grades.list',
          'schemaVersion': '1.1',
        },
      ],
    },
    'source':
        '''export const capabilities={
    'query.controls':async(ctx,p)=>{
      if($wait){ctx.log('info','synthetic_base_wait');await new Promise(()=>{});}
      return {target:p.target,title:'Synthetic',submitLabel:'Apply',controls:[{id:'term',kind:'text',label:'Term',required:true,initialValue:'A'}]};
    },
    'grades.list':async()=>({term:'synthetic',items:[]})
  };''',
  }),
);

Future<SessionController> prepare(
  WidgetTester tester,
  ScriptPackage package,
) async => (await tester.runAsync(() async {
  final session = SessionController();
  await session.bootstrap();
  await session.installTrustedScript(package, approvedDigest: package.digest);
  await session.selectTrustedScriptSchool(package.manifest.id);
  return session;
}))!;

Widget app(SessionController session, Widget child) => SessionScope(
  controller: session,
  child: MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  ),
);

void main() {
  testWidgets('closing a modal releases an unfinished base metadata request', (
    tester,
  ) async {
    final script = package(wait: true);
    final session = await prepare(tester, script);
    addTearDown(session.dispose);
    ScriptQuerySelection? selected;
    final oldEntries = DevLog.instance.entries.toSet();
    await tester.pumpWidget(
      app(
        session,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              selected = await pickScriptQueryControls(
                context,
                session,
                'grades.list',
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
      () => DevLog.instance.entries.any(
        (entry) =>
            !oldEntries.contains(entry) &&
            entry.message.contains('synthetic_base_wait'),
      ),
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(selected?.params, isNull);
    expect(selected?.supported, isTrue);
    bool? succeeded;
    final run = session
        .runTrustedScript(
          script.manifest.id,
          'grades.list',
          expectedDigest: script.digest,
          interactive: false,
        )
        .then((result) {
          succeeded = result.ok;
        });
    // Pump both the widget zone and native async work; the uncompleted
    // metadata promise otherwise owns the queue until its 35-second budget.
    await until(tester, () => succeeded != null);
    await run;
    expect(
      succeeded,
      isTrue,
      reason: 'the uncompleted JS promise must no longer own the queue',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'applied changes refresh the editor once; immediate leave retains scoped edits',
    (tester) async {
      final script = package();
      final session = await prepare(tester, script);
      addTearDown(session.dispose);
      final applied = ValueNotifier<Map<String, dynamic>>({});
      addTearDown(applied.dispose);
      final initial = <Map<String, dynamic>>[];
      Widget page() => app(
        session,
        ValueListenableBuilder<Map<String, dynamic>>(
          valueListenable: applied,
          builder: (_, current, _) => InlineScriptQueryControls(
            target: 'grades.list',
            current: current,
            submitInitial: true,
            onInitialSubmit: (value) {
              initial.add(value);
              applied.value = value;
            },
            onSubmit: (value) => applied.value = value,
            fallback: const Text('Unsupported'),
          ),
        ),
      );
      final field = find.byKey(const ValueKey('query-control-term'));
      await tester.pumpWidget(page());
      await until(
        tester,
        () => initial.isNotEmpty && field.evaluate().isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(initial, [
        {
          'filters': {'term': 'A'},
        },
      ]);
      applied.value = {
        'filters': {'term': 'B'},
      };
      await until(
        tester,
        () =>
            field.evaluate().isNotEmpty &&
            tester.widget<TextField>(field).controller!.text == 'B',
      );
      expect(initial.length, 1);
      await tester.enterText(field, 'saved draft');
      // Leave before the debounce: disposal must save without ancestor lookups.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      final saved = await tester.runAsync(
        () => session.cachedQueryForm(
          script.manifest.id,
          script.digest,
          'grades.list',
          {
            'current': {'term': 'B'},
          },
          draft: true,
        ),
      );
      expect(saved!['applied'], {'term': 'B'});
      expect(saved['edits'], {'term': 'saved draft'});
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(page());
      await until(tester, () => field.evaluate().isNotEmpty);
      expect(tester.widget<TextField>(field).controller!.text, 'saved draft');
      expect(initial.length, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
