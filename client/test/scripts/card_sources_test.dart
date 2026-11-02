// ADR-066: synthetic packages exercise the actual runtime, cache and native cards.
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

const _school = 'synthetic-card-sources';
const _baseId = 'school-source';
const _extraId = 'learning-source';

ScriptPackage _package(
  String id, {
  String version = '1.0.0',
  bool cards = false,
}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 12,
      'id': id,
      'version': version,
      'schoolId': _school,
      'name': 'Synthetic $id',
      'network': {'origins': []},
      'browser': false,
      'accounts': [],
      'capabilities': [
        for (final entry in [
          ['notice.list', '1.1'],
          ['notice.detail', '1.0'],
          ['generic.section', '1.0'],
        ])
          {
            'id': entry[0],
            'schema': 'elecon.${entry[0]}',
            'schemaVersion': entry[1],
          },
      ],
      'home': [
        {'capability': 'notice.list', 'ttlSeconds': 3600, 'preload': true},
      ],
      if (cards)
        'cards': [
          for (final entry in [
            ['learning', 'Learning notices'],
            ['department', 'Department notices'],
          ])
            {
              'type': 'notice',
              'id': entry[0],
              'title': entry[1],
              'defaultVariant': 'expanded',
            },
        ],
    },
    'source':
        '''export const capabilities = {
      'notice.list': async (ctx) => {
        const count = Number((await ctx.credentials.get('$id-count'))?.value ?? 0) + 1;
        await ctx.credentials.set('$id-count', String(count));
        return {sourceSystem:'$id',items:[{
          id:'shared-notice-id',title:'$id notice '+count,
          category:'academic',source:'Synthetic $id'
        }]};
      },
      'notice.detail': async (ctx,p) => ({
        id:p.id,title:'$id detail title',content:'$id detail body'
      }),
      'generic.section': async (ctx) => ({
        sectionId:'count',title:(await ctx.credentials.get('$id-count'))?.value ?? '0'
      })
    };''',
  }),
);

CapabilityQueries _queries(SessionController session, ScriptPackage package) =>
    CapabilityQueries(
      session,
      source: CapabilitySource(
        packageId: package.manifest.id,
        digest: package.digest,
      ),
    );

Future<(SessionController, ScriptPackage, ScriptPackage)> _prepare(
  WidgetTester tester,
) async {
  tester.view.physicalSize = const Size(1100, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final result = (await tester.runAsync(() async {
    final session = SessionController();
    await session.bootstrap();
    final base = _package(_baseId);
    final extra = _package(_extraId, cards: true);
    for (final package in [base, extra]) {
      await session.installTrustedScript(
        package,
        approvedDigest: package.digest,
      );
    }
    await session.selectTrustedScriptSchool(base.manifest.id);
    // Bind QuickJS's persistent host port to runAsync, never a disposed fake zone.
    expect(
      (await session.runCapability('generic.section', interactive: false)).ok,
      isTrue,
    );
    return (session, base, extra);
  }))!;
  addTearDown(result.$1.dispose);
  return result;
}

Future<String> _count(SessionController session, ScriptPackage package) async {
  final result = await _queries(
    session,
    package,
  ).runCapability('generic.section', interactive: false);
  expect(result.ok, isTrue, reason: result.reason);
  return (result.data as Map)['title'] as String;
}

String _source(Object? data) => (data as Map)['sourceSystem'] as String;

Widget _app(SessionController session, Widget child) => SessionScope(
  controller: session,
  child: MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  ),
);

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var n = 0; n < 300; n++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (ready()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  fail('Synthetic source-bound UI did not settle');
}

class _MemoryLayouts extends CardLayoutStore {
  final layout = HomeCardLayout();
  @override
  HomeCardLayout? cached(String scopeId) => layout;
  @override
  Future<HomeCardLayout> load(String scopeId) async => layout;
}

void main() {
  test(
    'SDK 12 preserves two distinct instances of the same native template',
    () {
      final cards = _package(_extraId, cards: true).manifest.cards;
      expect(cards.map((card) => card.type), ['notice', 'notice']);
      expect(cards.map((card) => card.id), ['learning', 'department']);
      expect(cards.map((card) => card.title), [
        'Learning notices',
        'Department notices',
      ]);
      expect(cards.every((card) => card.hasExplicitId), isTrue);
    },
  );

  testWidgets(
    'bound queries and parameter caches remain independent of the global provider',
    (tester) async {
      final (session, base, extra) = await _prepare(tester);
      await tester.runAsync(() async {
        final primary = _queries(session, base);
        final secondary = _queries(session, extra);
        final defaultRun = await session.runCapability(
          'notice.list',
          interactive: false,
        );
        expect(defaultRun.ok, isTrue, reason: defaultRun.reason);
        expect(_source(defaultRun.data), _baseId);
        final extraRun = await secondary.runCapability(
          'notice.list',
          params: {'page': 2},
          interactive: false,
        );
        expect(extraRun.ok, isTrue, reason: extraRun.reason);
        expect(_source(extraRun.data), _extraId);
        expect(
          _source((await primary.cachedCapability('notice.list'))!.data),
          _baseId,
        );
        expect(await secondary.cachedCapability('notice.list'), isNull);
        expect(
          _source(
            (await secondary.cachedCapability(
              'notice.list',
              params: {'page': 2},
            ))!.data,
          ),
          _extraId,
        );
        expect(
          (await secondary.latestCachedCapability('notice.list'))!.params,
          {'page': 2},
        );
        expect(
          (await session.scriptRegistry)
              .provider(_school, 'notice.list')!
              .manifest
              .id,
          _baseId,
        );

        await session.selectTrustedScriptProvider(
          _school,
          'notice.list',
          _extraId,
        );
        expect(
          _source((await primary.latestCachedCapability('notice.list'))!.data),
          _baseId,
        );
        expect(
          _source((await session.latestCachedCapability('notice.list'))!.data),
          _extraId,
        );
        expect(
          _source(
            (await primary.runCapability(
              'notice.list',
              interactive: false,
            )).data,
          ),
          _baseId,
        );
        expect(
          (await session.scriptRegistry)
              .provider(_school, 'notice.list')!
              .manifest
              .id,
          _extraId,
        );
      });
    },
  );

  testWidgets(
    'home preload includes non-global explicit cards once and honors TTL',
    (tester) async {
      final (session, base, extra) = await _prepare(tester);
      await tester.runAsync(() async {
        final unused = _package('unused-source');
        await session.installTrustedScript(
          unused,
          approvedDigest: unused.digest,
        );
        await session.refreshHomeData();
        expect(await _count(session, base), '1');
        expect(await _count(session, extra), '1');
        expect(await _count(session, unused), '0');
        expect(
          _source(
            (await _queries(
              session,
              extra,
            ).cachedCapability('notice.list'))!.data,
          ),
          _extraId,
        );
        expect(
          _source((await session.cachedCapability('notice.list'))!.data),
          _baseId,
        );
        await session.refreshHomeData();
        expect(await _count(session, extra), '1');
        await session.refreshHomeData(force: true);
        expect(await _count(session, base), '2');
        expect(await _count(session, extra), '2');
        expect(await _count(session, unused), '0');
      });
    },
  );

  for (final change in ['disable', 'update', 'remove']) {
    testWidgets(
      '$change revokes the original source and its cache without fallback',
      (tester) async {
        final (session, base, extra) = await _prepare(tester);
        await tester.runAsync(() async {
          await session.refreshHomeData();
          final original = _queries(session, extra);
          switch (change) {
            case 'disable':
              await session.enableTrustedScript(_extraId, false);
            case 'remove':
              await session.removeTrustedScript(_extraId);
            default:
              final update = _package(_extraId, version: '1.0.1', cards: true);
              await session.installTrustedScript(
                update,
                approvedDigest: update.digest,
              );
              expect(
                (await _queries(
                  session,
                  update,
                ).runCapability('notice.list', interactive: false)).ok,
                isTrue,
              );
          }
          expect(
            (await original.runCapability(
              'notice.list',
              interactive: false,
            )).ok,
            isFalse,
          );
          expect(await original.cachedCapability('notice.list'), isNull);
          expect(await original.latestCachedCapability('notice.list'), isNull);
          expect(
            _source((await session.cachedCapability('notice.list'))!.data),
            _baseId,
          );
          expect(
            await _count(session, base),
            '1',
            reason: 'revoked source must not call the default provider',
          );
        });
      },
    );
  }

  testWidgets(
    'scoped notice cards refresh separately and detail retains its source until revoked',
    (tester) async {
      final (session, base, extra) = await _prepare(tester);
      await tester.runAsync(() => session.refreshHomeData());
      await tester.pumpWidget(
        _app(
          session,
          Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  for (final (package, title) in [
                    (base, 'School notices'),
                    (extra, 'Learning notices'),
                  ])
                    CapabilitySourceScope(
                      key: ValueKey(package.manifest.id),
                      source: _queries(session, package).source!,
                      title: title,
                      child: const NoticeSection(),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await _until(
        tester,
        () => find.text('$_extraId notice 1').evaluate().isNotEmpty,
      );
      expect(find.text('School notices'), findsOneWidget);
      expect(find.text('Learning notices'), findsOneWidget);
      expect(find.text('$_baseId notice 1'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey(_extraId)),
          matching: find.byTooltip('Refresh'),
        ),
      );
      await _until(
        tester,
        () => find.text('$_extraId notice 2').evaluate().isNotEmpty,
      );
      expect(find.text('$_baseId notice 1'), findsOneWidget);
      await tester.tap(find.text('$_extraId notice 2'));
      await _until(
        tester,
        () => find.text('$_extraId detail body').evaluate().isNotEmpty,
      );
      expect(find.text('$_baseId detail body'), findsNothing);
      expect(
        tester.widget<NoticeDetailPage>(find.byType(NoticeDetailPage)).source,
        _queries(session, extra).source,
      );
      await tester.runAsync(() => session.enableTrustedScript(_extraId, false));
      await tester.pumpAndSettle();
      expect(find.text('$_extraId detail body'), findsNothing);
      await tester.tap(find.byType(BackButton));
      await _until(
        tester,
        () => find.text('$_baseId notice 1').evaluate().isNotEmpty,
      );
      expect(find.text('$_extraId notice 2'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'home keeps distinct same-type instance titles and removes only revoked cards',
    (tester) async {
      final (session, _, extra) = await _prepare(tester);
      await tester.runAsync(() => session.refreshHomeData());
      await tester.pumpWidget(
        _app(session, EleconHomePage(layoutStore: _MemoryLayouts())),
      );
      await _until(
        tester,
        () => find.text('Department notices').evaluate().isNotEmpty,
      );
      await _until(
        tester,
        () => find.text('$_extraId notice 1').evaluate().length == 2,
      );
      for (final id in ['learning', 'department']) {
        final card = find.byKey(ValueKey('home-card:script:$_extraId/$id'));
        expect(card, findsOneWidget);
        final notice = tester.widget<NoticeCard>(
          find.descendant(of: card, matching: find.byType(NoticeCard)),
        );
        expect(notice.data.items.single.source, 'Synthetic $_extraId');
      }
      expect(find.text('Learning notices'), findsOneWidget);
      expect(find.byKey(const ValueKey('home-card:notice')), findsOneWidget);
      await tester.runAsync(
        () => session.enableTrustedScript(extra.manifest.id, false),
      );
      await _until(
        tester,
        () =>
            find.text('Department notices').evaluate().isEmpty &&
            find
                .byKey(const ValueKey('home-card:notice'))
                .evaluate()
                .isNotEmpty,
      );
      expect(find.text('Learning notices'), findsNothing);
      expect(find.byKey(const ValueKey('home-card:notice')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
