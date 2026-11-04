import 'dart:convert';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/home/home_page.dart';
import 'package:elecon/ui/home/card_layout.dart';
import 'package:elecon/ui/home/card_layout_store.dart';
import 'package:elecon/ui/home/script_feature_page.dart';
import 'package:elecon/ui/shell/main_shell.dart';
import 'package:elecon/ui/theme/theme_controller.dart';
import 'package:elecon/ui/theme/theme_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ScriptPackage package({
  String version = '1.0.0',
  bool tabs = true,
  bool boundWithoutId = false,
}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 18,
      'id': 'synthetic-pages',
      'version': version,
      'schoolId': 'synthetic-pages',
      'name': 'Page fixture',
      'browser': false,
      'network': {'origins': []},
      'accounts': [],
      'capabilities': [
        for (final cap in ['generic.section', 'forum.session'])
          {'id': cap, 'schema': 'elecon.$cap', 'schemaVersion': '1.0'},
      ],
      if (boundWithoutId)
        'cards': [
          {'type': 'generic', 'defaultVariant': 'regular', 'pageId': 'page-0'},
        ],
      'pages': [
        for (var i = 0; i < 4; i++)
          {
            'id': 'page-$i',
            'title': 'Portal $i',
            'template': 'generic',
            'tab': tabs,
          },
      ],
    },
    'source':
        "export const capabilities={'generic.section':async()=>({sectionId:'synthetic',title:'Fixture content',items:[]})};",
  }),
);

Widget app(SessionController session, Widget child) {
  final theme = ThemeController();
  addTearDown(theme.dispose);
  return ThemeScope(
    controller: theme,
    child: SessionScope(
      controller: session,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: child,
      ),
    ),
  );
}

class _MemoryLayout extends CardLayoutStore {
  @override
  Future<HomeCardLayout> load(String scopeId) async => HomeCardLayout(
    sizes: {'script:synthetic-pages/generic': HomeCardSize.compact},
  );
}

void main() {
  testWidgets('page binding without an explicit card id opens its fixed page', (
    tester,
  ) async {
    final session = SessionController();
    final source = package(tabs: false, boundWithoutId: true);
    expect(source.manifest.cards.single.hasExplicitId, isFalse);
    expect(source.manifest.cards.single.id, 'generic');
    await session.installTrustedScript(source, approvedDigest: source.digest);
    await session.selectTrustedScriptSchool(source.manifest.id);
    await tester.pumpWidget(
      app(session, EleconHomePage(layoutStore: _MemoryLayout())),
    );
    await tester.pumpAndSettle();
    final card = find.byKey(
      const ValueKey('home-card:script:synthetic-pages/generic'),
    );
    for (var i = 0; i < 50 && card.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(card, findsOneWidget);
    expect(
      find.byKey(const ValueKey('home-card:page:synthetic-pages/page-0')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(
        const ValueKey('home-card-open:script:synthetic-pages/generic'),
      ),
    );
    await tester.pumpAndSettle();
    final page = tester.widget<ScriptFeaturePage>(
      find.byType(ScriptFeaturePage),
    );
    expect(page.page.id, 'page-0');
    expect(page.package.digest, source.digest);
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
  });

  testWidgets(
    'three declared tabs preserve home/settings and suppress legacy forum',
    (tester) async {
      final session = SessionController();
      final source = package();
      await session.installTrustedScript(source, approvedDigest: source.digest);
      await session.selectTrustedScriptSchool(source.manifest.id);
      await tester.pumpWidget(
        app(
          session,
          MainShell(
            loadHomeSnapshot: () async =>
                const CampusSnapshot(schoolName: 'Synthetic', updatedAt: null),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Portal 0'), findsOneWidget);
      expect(find.text('Portal 1'), findsOneWidget);
      expect(find.text('Portal 2'), findsOneWidget);
      expect(find.text('Portal 3'), findsNothing);
      expect(find.text('Forum'), findsNothing);
      expect(find.text('Settings'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    },
  );

  testWidgets(
    'an opened page loses its content when the approved source changes',
    (tester) async {
      final session = SessionController();
      final source = package(tabs: false);
      await session.installTrustedScript(source, approvedDigest: source.digest);
      await session.selectTrustedScriptSchool(source.manifest.id);
      await tester.pumpWidget(
        app(
          session,
          ScriptFeaturePage(package: source, page: source.manifest.pages.first),
        ),
      );
      await tester.pump();
      final next = package(version: '1.0.1', tabs: false);
      await session.installTrustedScript(next, approvedDigest: next.digest);
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(ScriptFeaturePage));
      expect(
        find.text(AppLocalizations.of(context).homeCardDataChanged),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    },
  );
}
