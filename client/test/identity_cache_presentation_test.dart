// Synthetic accounts exercise the real session's explicit login boundary.
import 'dart:async';
import 'dart:convert';

import 'package:elecon/core/adapter_service.dart';
import 'package:elecon/core/loader/diagnostics.dart';
import 'package:elecon/core/scripts/account_auth.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/home/home_page.dart';
import 'package:elecon/ui/home/card_layout.dart';
import 'package:elecon/ui/home/feature_page.dart';
import 'package:elecon/ui/home/query_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'scripts/account_password_test.dart' show passwordPackage;
import 'home_card_layout_integration_test.dart' show LayoutMemory;

ScriptPackage package({bool cached = true}) {
  final raw =
      jsonDecode(
            passwordPackage(
              source: '''
    export const capabilities={
      'account.session':async ctx=>{
        const attempt=await ctx.accounts.password('school',{mode:'manual'});
        await ctx.credentials.set('principal',attempt.username);
        await ctx.accounts.completePassword('school',{attemptId:attempt.attemptId,outcome:'authenticated'});
        return {status:'authenticated'};
      },
      'notice.list':async ctx=>{
        const principal=(await ctx.credentials.get('principal')).value;
        return {principal,items:[{id:'synthetic',title:principal,category:'unknown',source:'Synthetic'}]};
      }
    };
  ''',
            ).encode(),
          )
          as Map<String, dynamic>;
  if (cached) {
    raw['manifest']['home'] = [
      {'capability': 'notice.list', 'ttlSeconds': 3600, 'preload': false},
    ];
  }
  return ScriptPackage.parse(jsonEncode(raw));
}

Future<void> login(
  SessionController session,
  ScriptPackage package,
  String username,
) async {
  final result = await session.runTrustedScript(
    package.manifest.id,
    'account.session',
    expectedDigest: package.digest,
    params: const {'account': 'school', 'operation': 'login'},
    passwordCall: (_) async => ScriptPasswordInput(
      username: username,
      password: 'synthetic-password',
      remember: true,
    ),
  );
  expect(result.ok, isTrue, reason: result.reason);
}

Future<void> initialize(
  SessionController session,
  ScriptPackage package,
) async {
  await session.installTrustedScript(package, approvedDigest: package.digest);
  await session.selectTrustedScriptSchool(package.manifest.id);
  await login(session, package, 'Synthetic account A');
}

Widget app(SessionController session, Widget child) => SessionScope(
  controller: session,
  child: MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  ),
);

class QueryView extends StatefulWidget {
  const QueryView({super.key});
  @override
  State<QueryView> createState() => QueryViewState();
}

class QueryViewState extends State<QueryView>
    with CachedQuerySection<QueryView, String> {
  String? data;
  @override
  String get cacheCapability => 'notice.list';
  @override
  String? decodeCache(Object? raw) => (raw as Map?)?['principal'] as String?;
  @override
  void applyCache(String value) => data = value;
  @override
  void clearCache() => data = null;
  Future<void> load() async {
    final result = await runOnceDecoded<String>(
      SessionScope.of(context),
      'notice.list',
      decode: decodeCache,
    );
    if (mounted) setState(() => data = result.data);
  }

  @override
  Widget build(BuildContext context) => Text(data ?? 'No identity data');
}

class DelayedQuerySession extends SessionController {
  final pending = Completer<CapabilityRun>();
  @override
  Future<CapabilityRun> runCapability(
    String capability, {
    Map<String, dynamic>? params,
    bool interactive = true,
    ScriptRunCancellation? cancellation,
    String? htmlStdlib,
    void Function(String, String)? onLog,
    void Function(AdapterDiagnostic)? onDiagnostic,
  }) => pending.future;
}

void main() {
  for (final cached in [true, false]) {
    testWidgets(
      'login clears ${cached ? 'restored cache' : 'uncached manual result'} and preserves execution generation',
      (tester) async {
        final p = package(cached: cached);
        final session = SessionController();
        addTearDown(session.dispose);
        await tester.runAsync(() async {
          await initialize(session, p);
          if (cached) {
            expect((await session.runCapability('notice.list')).ok, isTrue);
          }
        });
        final key = GlobalKey<QueryViewState>();
        await tester.pumpWidget(app(session, QueryView(key: key)));
        // Runtime writes happen on the real clock while widget time is frozen.
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(key.currentState!.restoreCache);
        await tester.pumpAndSettle();
        if (!cached) {
          await tester.runAsync(key.currentState!.load);
          await tester.pump();
        }
        expect(find.text('Synthetic account A'), findsOneWidget);
        final generation = session.trustedScriptViewGeneration;
        await tester.runAsync(() => login(session, p, 'Synthetic account B'));
        await tester.pumpAndSettle();
        expect(session.trustedScriptViewGeneration, generation);
        expect(find.text('Synthetic account A'), findsNothing);
        expect(find.text('No identity data'), findsOneWidget);
        await tester.runAsync(key.currentState!.load);
        await tester.pumpAndSettle();
        expect(find.text('Synthetic account B'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  test(
    'a decoded query discards a previous account result arriving after login',
    () async {
      final p = package();
      final session = DelayedQuerySession();
      addTearDown(session.dispose);
      await initialize(session, p);
      final result = runOnceDecoded<String>(
        session,
        'notice.list',
        decode: (data) => (data as Map)['principal'] as String,
      );
      await login(session, p, 'Synthetic account B');
      session.pending.complete(
        const CapabilityRun.ok({'principal': 'Synthetic account A'}),
      );
      final outcome = await result;
      expect(outcome.data, isNull);
      expect(outcome.reason, 'script_cancelled');
    },
  );

  testWidgets('an open notice detail drops its original account content', (
    tester,
  ) async {
    final p = package();
    final session = SessionController();
    addTearDown(session.dispose);
    await tester.runAsync(() => initialize(session, p));
    await tester.pumpWidget(
      app(
        session,
        const NoticeDetailPage(
          item: NoticeListItems(
            id: 'synthetic',
            title: 'Synthetic private notice',
            category: 'unknown',
            source: 'Synthetic',
            content: 'Synthetic account A body',
          ),
        ),
      ),
    );
    expect(find.text('Synthetic account A body'), findsOneWidget);
    await tester.runAsync(() => login(session, p, 'Synthetic account B'));
    await tester.pumpAndSettle();
    expect(find.text('Synthetic account A body'), findsNothing);
    expect(find.text('Synthetic private notice'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'home does not retain the previous identity snapshot while reloading',
    (tester) async {
      final p = package();
      final session = SessionController();
      addTearDown(session.dispose);
      await tester.runAsync(() async {
        await initialize(session, p);
        expect((await session.runCapability('notice.list')).ok, isTrue);
      });
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(
        app(session, EleconHomePage(layoutStore: LayoutMemory())),
      );
      for (
        var i = 0;
        i < 100 && find.text('Synthetic account A').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(find.text('Synthetic account A'), findsOneWidget);
      await tester.runAsync(() => login(session, p, 'Synthetic account B'));
      await tester.pump();
      expect(find.text('Synthetic account A'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('an open feature rejects the previous identity snapshot', (
    tester,
  ) async {
    final p = package();
    final session = SessionController();
    addTearDown(session.dispose);
    await tester.runAsync(() => initialize(session, p));
    final active = ValueNotifier(true);
    addTearDown(active.dispose);
    await tester.pumpWidget(
      app(
        session,
        HomeFeaturePage(
          card: HomeCardEntry(
            id: 'synthetic',
            label: 'Synthetic feature',
            builder: (_) => const Text('Synthetic account A feature'),
          ),
          contentKey: GlobalKey(),
          active: active,
          onClosed: () {},
          session: session,
          generation: session.trustedScriptViewGeneration,
          dataGeneration: session.trustedScriptDataGeneration,
        ),
      ),
    );
    expect(find.text('Synthetic account A feature'), findsOneWidget);
    await tester.runAsync(() => login(session, p, 'Synthetic account B'));
    await tester.pumpAndSettle();
    expect(find.text('Synthetic account A feature'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
