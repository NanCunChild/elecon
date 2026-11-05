// ADR-066: synthetic source binding and read-only preload recovery through QuickJS.
import 'dart:convert';

import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/home/capability_source.dart';
import 'package:elecon/ui/home/card_layout.dart';
import 'package:elecon/ui/home/card_layout_store.dart';
import 'package:elecon/ui/home/home_page.dart';
import 'package:elecon/ui/home/notice_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ScriptPackage source(
  String id, {
  bool list = true,
  bool detail = true,
  bool fail = false,
  int delayMs = 0,
}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 12,
      'id': id,
      'version': '1.0.0',
      'schoolId': 'synthetic-notice-flow',
      'name': 'Synthetic $id',
      'network': {'origins': []},
      'browser': false,
      'accounts': [],
      'capabilities': [
        for (final cap in [
          if (list) 'notice.list',
          if (detail) 'notice.detail',
          'generic.section',
        ])
          {
            'id': cap,
            'schema': 'elecon.$cap',
            'schemaVersion': cap == 'notice.list' ? '1.1' : '1.0',
          },
      ],
      if (list)
        'home': [
          {'capability': 'notice.list', 'ttlSeconds': 3600, 'preload': true},
        ],
    },
    'source':
        '''
    const count=async(ctx,key)=>{const n=Number((await ctx.credentials.get(key))?.value??0)+1;await ctx.credentials.set(key,String(n));return n;};
    export const capabilities={
      'notice.list':async ctx=>{await count(ctx,'lists');if($fail||(await ctx.credentials.get('expired'))?.value==='true'){const e=new Error('authentication_required');e.code='authentication_required';throw e;}if($delayMs)await new Promise(r=>setTimeout(r,$delayMs));return {items:[{id:'shared-id',title:'$id notice',category:'academic',source:'$id'}]};},
      'notice.detail':async(ctx,p)=>{await count(ctx,'details');return {id:p.id,title:'$id detail',content:'$id body'};},
      'generic.section':async(ctx,p)=>{if(p.expire)await ctx.credentials.set('expired','true');return {sectionId:'counts',title:(await ctx.credentials.get(p.key??'lists'))?.value??'0'};}
    };
  ''',
  }),
);

CapabilitySource binding(ScriptPackage p) =>
    CapabilitySource(packageId: p.manifest.id, digest: p.digest);
Widget app(SessionController s, Widget child) => SessionScope(
  controller: s,
  child: MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  ),
);
Future<void> until(WidgetTester t, bool Function() ready) async {
  for (var i = 0; i < 250; i++) {
    await t.pump(const Duration(milliseconds: 20));
    if (ready()) return;
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  fail('Synthetic notice flow did not settle');
}

Future<SessionController> prepare(
  WidgetTester t,
  List<ScriptPackage> packages,
) async {
  t.view.physicalSize = const Size(1000, 1600);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  final s = (await t.runAsync(() async {
    final s = SessionController();
    await s.bootstrap();
    for (final p in packages) {
      await s.installTrustedScript(p, approvedDigest: p.digest);
    }
    await s.selectTrustedScriptSchool(packages.first.manifest.id);
    expect(
      (await s.runCapability('generic.section', interactive: false)).ok,
      isTrue,
    );
    return s;
  }))!;
  addTearDown(s.dispose);
  return s;
}

Future<String> count(
  SessionController s,
  ScriptPackage p, {
  String key = 'lists',
}) async {
  final result = await CapabilityQueries(
    s,
    source: binding(p),
  ).runCapability('generic.section', params: {'key': key}, interactive: false);
  expect(result.ok, isTrue);
  return (result.data as Map)['title'] as String;
}

class MemoryLayouts extends CardLayoutStore {
  final value = HomeCardLayout(sizes: const {'notice': HomeCardSize.expanded});
  @override
  HomeCardLayout? cached(String scopeId) => value;
  @override
  Future<HomeCardLayout> load(String scopeId) async => value;
}

void main() {
  testWidgets('authentication failure remains visible beside cached notices', (
    t,
  ) async {
    final p = source('cached-login');
    final s = await prepare(t, [p]);
    await t.runAsync(() => s.refreshHomeData());
    await t.pumpWidget(
      app(
        s,
        Scaffold(
          body: CapabilitySourceScope(
            source: binding(p),
            child: const NoticeSection(),
          ),
        ),
      ),
    );
    await until(
      t,
      () => find.text('cached-login notice').evaluate().isNotEmpty,
    );
    await t.runAsync(
      () => s.runTrustedScript(
        p.manifest.id,
        'generic.section',
        params: {'expire': true},
        interactive: false,
      ),
    );
    await t.tap(find.byTooltip('Refresh'));
    await until(t, () => find.text('登录并查看').evaluate().isNotEmpty);
    expect(find.text('cached-login notice'), findsOneWidget);
    await t.pump(const Duration(seconds: 1));
    expect(find.text('登录并查看'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'default notice card freezes list source when another detail candidate exists',
    (t) async {
      final a = source('list-source'), b = source('other-detail', list: false);
      final s = await prepare(t, [a, b]);
      await t.runAsync(() async {
        await s.refreshHomeData();
      });
      await t.pumpWidget(app(s, EleconHomePage(layoutStore: MemoryLayouts())));
      await until(t, () => find.byType(NoticeSection).evaluate().isNotEmpty);
      expect(
        CapabilitySourceScope.maybeOf(
          t.element(find.byType(NoticeSection).first),
        )?.source,
        binding(a),
      );
      await until(
        t,
        () => find.text('list-source notice').evaluate().isNotEmpty,
      );
      // The summary directly opens this notice, preserving the list source.
      await t.tap(find.byKey(const ValueKey('notice-summary-shared-id')));
      await t.pump();
      await until(t, () => find.text('list-source body').evaluate().isNotEmpty);
      expect(find.text('other-detail body'), findsNothing);
      await t.runAsync(() async {
        expect(await count(s, b, key: 'details'), '0');
      });
      await t.pumpWidget(const SizedBox.shrink());
    },
  );
  for (final failPreload in [false, true]) {
    testWidgets(
      'preload ${failPreload ? 'auth failure gets one read-only recovery' : 'success is not requested again'}',
      (t) async {
        final p = source(
          'preload-source',
          fail: failPreload,
          delayMs: failPreload ? 0 : 300,
        );
        final s = await prepare(t, [p]);
        var browserCalls = 0, inputCalls = 0;
        s.scriptBrowserPresenter = (p, execute) async {
          browserCalls++;
          throw StateError('Unexpected browser');
        };
        s.scriptInputPresenter = (p, execute) async {
          inputCalls++;
          throw StateError('Unexpected input');
        };
        Future<void>? preload;
        await t.runAsync(() async {
          preload = s.refreshHomeData();
          if (failPreload) await preload;
        });
        await t.pumpWidget(
          app(
            s,
            Scaffold(
              body: CapabilitySourceScope(
                source: binding(p),
                child: const NoticeSection(),
              ),
            ),
          ),
        );
        await until(
          t,
          () => find
              .text(failPreload ? '登录并查看' : 'preload-source notice')
              .evaluate()
              .isNotEmpty,
        );
        await t.runAsync(() async {
          expect(await count(s, p), failPreload ? '2' : '1');
        });
        await t.pump(const Duration(seconds: 1));
        await t.runAsync(() async {
          expect(await count(s, p), failPreload ? '2' : '1');
        });
        expect(browserCalls, 0);
        expect(inputCalls, 0);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  testWidgets(
    'list-only source shows absent body without querying another detail source',
    (t) async {
      final a = source('list-only', detail: false),
          b = source('other-detail', list: false);
      final s = await prepare(t, [a, b]);
      await t.pumpWidget(
        app(
          s,
          NoticeDetailPage(
            source: binding(a),
            item: const NoticeListItems(
              id: 'shared-id',
              title: 'No body',
              category: 'academic',
              source: 'Synthetic',
            ),
          ),
        ),
      );
      await until(
        t,
        () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      final l = AppLocalizations.of(t.element(find.byType(NoticeDetailPage)));
      expect(find.text(l.noticeDetailEmpty), findsOneWidget);
      expect(find.text(l.noticeDetailFailed), findsNothing);
      await t.runAsync(() async {
        expect(await count(s, b, key: 'details'), '0');
      });
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
    },
  );
}
