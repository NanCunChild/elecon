// SDK-3 native forms: synthetic identities and values, no school traffic.
import 'dart:async';
import 'dart:convert';

import 'package:elecon/core/scripts/input.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/ui/scripts/script_input_presenter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'input_test.dart' show package, form;

Widget app(Widget home) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: ThemeData(useMaterial3: true),
  home: Scaffold(body: home),
);
Future<void> until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 300; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (done()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  fail('Input UI did not finish');
}

void main() {
  setUp(() {});
  testWidgets(
    'fixed dialog renders text, password, choices and optional fields',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Map<String, String>? result;
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                await presentScriptInput(
                  context,
                  package('return {items:[]};'),
                  (input) async {
                    result =
                        await input(ScriptInputRequest.fromJson(form))
                            as Map<String, String>?;
                    return null;
                  },
                );
              },
              child: const Text('Ask'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Ask'));
      await tester.pumpAndSettle();
      expect(find.text('Synthetic school · synthetic'), findsOneWidget);
      final secret = find.byKey(const ValueKey('script-input-password'));
      final editor = tester.widget<TextField>(
        find.descendant(of: secret, matching: find.byType(TextField)),
      );
      expect(editor.obscureText, isTrue);
      expect(editor.enableSuggestions, isFalse);
      expect(editor.autocorrect, isFalse);
      await tester.tap(find.text('Submit and continue'));
      await tester.pump();
      expect(find.text('Enter or select a valid value'), findsWidgets);
      await tester.enterText(
        find.byKey(const ValueKey('script-input-account')),
        'SYNTHETIC-ID',
      );
      await tester.enterText(secret, 'SYNTHETIC-PASSWORD');
      await tester.tap(find.byKey(const ValueKey('script-input-campus')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('North').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Submit and continue'));
      await tester.pumpAndSettle();
      expect(result, {
        'account': 'SYNTHETIC-ID',
        'password': 'SYNTHETIC-PASSWORD',
        'campus': 'north',
        'note': '',
      });
      expect(find.text('School script requests information'), findsNothing);
    },
  );
  testWidgets(
    'cancel returns null and completing the caller closes an outstanding form',
    (tester) async {
      Object? result = 'pending';
      final end = Completer<Object?>();
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => Column(
              children: [
                TextButton(
                  onPressed: () async {
                    await presentScriptInput(
                      context,
                      package('return {items:[]};'),
                      (input) async {
                        result = await input(
                          ScriptInputRequest.fromJson({
                            'title': 'T',
                            'fields': [
                              {'id': 'x', 'label': 'X'},
                            ],
                          }),
                        );
                        return null;
                      },
                    );
                  },
                  child: const Text('Cancel case'),
                ),
                TextButton(
                  onPressed: () async {
                    await presentScriptInput(
                      context,
                      package('return {items:[]};'),
                      (input) async {
                        unawaited(
                          input(
                            ScriptInputRequest.fromJson({
                              'title': 'T',
                              'fields': [
                                {'id': 'x', 'label': 'X'},
                              ],
                            }),
                          ).catchError((_) => (null)),
                        );
                        return end.future;
                      },
                    );
                  },
                  child: const Text('End case'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('Cancel case'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(result, isNull);
      await tester.tap(find.text('End case'));
      await tester.pumpAndSettle();
      expect(find.text('School script requests information'), findsOneWidget);
      end.complete(null);
      await tester.pumpAndSettle();
      expect(find.text('School script requests information'), findsNothing);
    },
  );
  testWidgets(
    'destroying the calling page closes the form and cancels its invocation',
    (tester) async {
      var cancelled = false, failed = false;
      var inputSettled = false;
      final request = ScriptInputRequest.fromJson({
        'title': 'T',
        'fields': [
          {'id': 'x', 'label': 'X'},
        ],
      });
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                try {
                  await presentScriptInput(
                    context,
                    package('return {items:[]};'),
                    (input) async {
                      try {
                        return await input(request);
                      } finally {
                        inputSettled = true;
                      }
                    },
                    onCancel: () => cancelled = true,
                  );
                } catch (_) {
                  failed = true;
                }
              },
              child: const Text('Ask'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Ask'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(app(const Text('Replacement page')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      await until(tester, () => inputSettled);
      expect(cancelled, isTrue);
      expect(failed, isTrue);
      expect(inputSettled, isTrue);
      expect(find.text('School script requests information'), findsNothing);
    },
  );
  for (final action in ['switch', 'logout', 'disable', 'update']) {
    testWidgets(
      '$action closes a real SDK-3 form and blocks late credential writes',
      (tester) async {
        final session = await tester.runAsync(() async {
          final s = SessionController();
          await s.bootstrap();
          s.scriptStorageConsent = () async => false;
          final p = package(
            'const r=await ctx.ui.requestInput({title:"T",fields:[{id:"x",label:"X"}]});if(r)await ctx.credentials.set("late",r.x);return {items:[]};',
          );
          await s.installTrustedScript(p, approvedDigest: p.digest);
          final other = jsonDecode(p.encode()) as Map<String, dynamic>;
          (other['manifest'] as Map)['id'] = 'other';
          (other['manifest'] as Map)['schoolId'] = 'other';
          final q = ScriptPackage.parse(jsonEncode(other));
          await s.installTrustedScript(q, approvedDigest: q.digest);
          await s.selectTrustedScriptSchool(p.manifest.id);
          return s;
        });
        addTearDown(session!.dispose);
        bool? ok;
        await tester.pumpWidget(
          app(
            Builder(
              builder: (context) {
                session.scriptInputPresenter = (p, execute) =>
                    presentScriptInput(
                      context,
                      p,
                      execute,
                      onCancel: session.cancelTrustedScriptRuns,
                    );
                return TextButton(
                  onPressed: () async {
                    ok = (await session.runTrustedScript(
                      'input.synthetic',
                      'notice.list',
                    )).ok;
                  },
                  child: const Text('Run'),
                );
              },
            ),
          ),
        );
        await tester.tap(find.text('Run'));
        await until(
          tester,
          () => find
              .text('School script requests information')
              .evaluate()
              .isNotEmpty,
        );
        await tester.pumpAndSettle();
        final lateSubmit = tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Submit and continue'),
            )
            .onPressed!;
        await tester.runAsync(() async {
          switch (action) {
            case 'switch':
              await session.selectTrustedScriptSchool('other');
            case 'logout':
              session.logout();
            case 'disable':
              await session.enableTrustedScript('input.synthetic', false);
            case 'update':
              final installed = (await session.scriptRegistry)
                  .find('input.synthetic')!
                  .package;
              final json =
                  jsonDecode(installed.encode()) as Map<String, dynamic>;
              (json['manifest'] as Map)['version'] = '1.0.1';
              json['source'] =
                  'export const capabilities={"notice.list":async()=>({items:[]})};';
              final next = ScriptPackage.parse(jsonEncode(json));
              await session.installTrustedScript(
                next,
                approvedDigest: next.digest,
              );
          }
        });
        await until(tester, () => ok != null);
        await tester.pumpAndSettle();
        expect(ok, isFalse);
        expect(session.credentialCount, 0);
        expect(find.text('School script requests information'), findsNothing);
        expect(lateSubmit, returnsNormally);
      },
    );
  }
}
