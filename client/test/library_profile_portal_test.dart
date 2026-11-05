import 'dart:convert';
import 'dart:async';
import 'package:elecon/core/adapter_service.dart';
import 'package:elecon/core/loader/diagnostics.dart';
import 'package:elecon/ui/home/library_section.dart';
import 'package:elecon/ui/home/card_layout.dart';
import 'package:elecon/ui/home/capability_source.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/home/library_search_section.dart';
import 'package:elecon/ui/settings/script_profile_name.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ScriptPackage fixture() => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 4,
      'id': 'library.synthetic',
      'version': '1.0.0',
      'schoolId': 'synthetic',
      'name': 'Synthetic',
      'browser': false,
      'network': {'origins': []},
      'capabilities': [
        for (final id in ['library.search', 'profile.me'])
          {'id': id, 'schema': 'elecon.$id', 'schemaVersion': '1.0'},
      ],
      'home': [
        for (final id in ['library.search', 'profile.me'])
          {'capability': id, 'ttlSeconds': 3600},
      ],
    },
    'source': '''export const capabilities = {
    'profile.me': async () => ({name: '合成姓名'}),
    'library.search': async (ctx,p) => ({query:p.query,page:p.page||1,size:p.size||10,hasNext:false,
      items:[{bookId:'synthetic-book',title:'合成书目',author:'合成作者'}]})
  };''',
  }),
);
Widget app(SessionController session, Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('zh'),
  home: SessionScope(
    controller: session,
    child: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

class QuerySession extends SessionController {
  final calls = <Map<String, dynamic>>[];
  final responses = <Future<CapabilityRun>>[];
  @override
  Future<CapabilityRun> runCapability(
    String capability, {
    Map<String, dynamic>? params,
    bool interactive = true,
    ScriptRunCancellation? cancellation,
    String? htmlStdlib,
    void Function(String, String)? onLog,
    void Function(AdapterDiagnostic)? onDiagnostic,
  }) {
    calls.add({
      'capability': capability,
      'interactive': interactive,
      ...?params,
    });
    return responses.removeAt(0);
  }
}

Map<String, dynamic> book(String query, {int page = 1, int size = 10}) => {
  'query': query,
  'page': page,
  'size': size,
  'hasNext': page == 1,
  'items': [
    {'bookId': '$query-$page', 'title': '$query book $page'},
  ],
};

void main() {
  testWidgets(
    'book pagination binds submitted keywords, rejects size mismatch and preserves failed refresh',
    (tester) async {
      final session = QuerySession();
      addTearDown(session.dispose);
      session.responses.add(Future.value(CapabilityRun.ok(book('First'))));
      await tester.pumpWidget(app(session, const LibrarySearchSection()));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'First');
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(find.text('First book 1'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Unsubmitted');
      session.responses.add(
        Future.value(CapabilityRun.ok(book('First', page: 2))),
      );
      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();
      expect(session.calls.last['query'], 'First');
      expect(session.calls.last['page'], 2);
      expect(find.text('First book 2'), findsOneWidget);
      session.responses.add(
        Future.value(
          const CapabilityRun.failed(CapabilityFailureKind.run, 'offline'),
        ),
      );
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(find.text('First book 2'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'New');
      session.responses.add(
        Future.value(CapabilityRun.ok(book('New', size: 20))),
      );
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(find.text('First book 2'), findsNothing);
      expect(find.text('New book 1'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'profile lookup starts only after activation and discards an inactive late name',
    (tester) async {
      final session = QuerySession();
      addTearDown(session.dispose);
      await tester.runAsync(() async {
        await session.bootstrap();
        final package = fixture();
        await session.installTrustedScript(
          package,
          approvedDigest: package.digest,
        );
        await session.selectTrustedScriptSchool(package.manifest.id);
      });
      final pending = Completer<CapabilityRun>();
      session.responses.add(pending.future);
      Future<void> render(bool active) async {
        await tester.pumpWidget(
          app(
            session,
            ScriptProfileName(
              session: session,
              fallback: 'Fallback',
              active: active,
            ),
          ),
        );
        await tester.runAsync(() async {});
        await tester.pumpAndSettle();
      }

      await render(false);
      expect(session.calls, isEmpty);
      await render(true);
      expect(session.calls.single['interactive'], isFalse);
      await render(false);
      pending.complete(const CapabilityRun.ok({'name': 'Late name'}));
      await tester.pumpAndSettle();
      expect(find.text('Fallback'), findsOneWidget);
      expect(find.text('Late name'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'library detail retains separate search and loan titles under a script title',
    (tester) async {
      final session = SessionController();
      addTearDown(session.dispose);
      late ScriptPackage package;
      await tester.runAsync(() async {
        await session.bootstrap();
        package = fixture();
        await session.installTrustedScript(
          package,
          approvedDigest: package.digest,
        );
        await session.selectTrustedScriptSchool(package.manifest.id);
      });
      await tester.pumpWidget(
        app(
          session,
          CapabilitySourceScope(
            source: CapabilitySource(
              packageId: package.manifest.id,
              digest: package.digest,
            ),
            title: 'Script library title',
            child: const HomeCardPresentation(
              size: HomeCardSize.expanded,
              isPage: true,
              child: LibraryLoansSection(),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {});
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(
        tester.element(find.byType(LibraryLoansSection)),
      );
      expect(find.text(l10n.librarySearchTitle), findsWidgets);
      expect(find.text(l10n.homeLibraryLoansTitle), findsOneWidget);
      expect(find.text('Script library title'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'book decoder preserves bibliographic identity and rejects malformed output',
    () {
      final data = {
        'query': 'book',
        'page': 1,
        'size': 10,
        'hasNext': false,
        'items': [
          {'bookId': 'id', 'title': 'Title', 'callNumber': 'TP1'},
        ],
      };
      expect(librarySearchFromDynamic(data)!.items.single.callNumber, 'TP1');
      expect(
        librarySearchFromDynamic({
          ...data,
          'items': [
            {'title': 'no identity'},
          ],
        }),
        isNull,
      );
      expect(
        librarySearchFromDynamic({
          ...data,
          'items': [
            data['items'] is List ? (data['items'] as List).first : null,
            (data['items'] as List).first,
          ],
        }),
        isNull,
      );
    },
  );
  testWidgets('book result restores on remount and profile uses script name', (
    tester,
  ) async {
    final session = SessionController();
    await tester.runAsync(() async {
      await session.bootstrap();
      final package = fixture();
      await session.installTrustedScript(
        package,
        approvedDigest: package.digest,
      );
      await session.selectTrustedScriptSchool(package.manifest.id);
      expect(
        (await session.runCapability(
          'library.search',
          params: {'query': '合成', 'page': 1, 'size': 10},
        )).ok,
        isTrue,
      );
      expect((await session.runCapability('profile.me')).ok, isTrue);
    });
    Future<void> render() async {
      await tester.pumpWidget(
        app(
          session,
          Column(
            children: [
              const LibrarySearchSection(),
              ScriptProfileName(
                session: session,
                fallback: 'Profile 1',
                active: true,
              ),
            ],
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pumpAndSettle();
    }

    await render();
    expect(find.text('合成书目'), findsOneWidget);
    expect(find.text('合成姓名'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '合成',
    );
    await tester.pumpWidget(const SizedBox());
    await render();
    expect(find.text('合成书目'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
