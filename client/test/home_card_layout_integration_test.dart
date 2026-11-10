import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/ui/home/card_layout.dart';
import 'package:elecon/ui/home/card_layout_store.dart';
import 'package:elecon/ui/home/home_page.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class SourceSession extends SessionController {
  void changeSource() {
    cancelTrustedScriptRuns();
    notifyListeners();
  }
}

class LayoutMemory extends CardLayoutStore {
  final values = <String, HomeCardLayout>{};
  @override
  Future<HomeCardLayout> load(String scopeId) async =>
      values[scopeId] ?? HomeCardLayout();
  @override
  Future<void> save(String scopeId, HomeCardLayout layout) async {
    values[scopeId] = layout;
  }
}

CampusSnapshot snapshot() => CampusSnapshot(
  schoolName: 'Synthetic university',
  updatedAt: DateTime.utc(2026, 10, 31),
  notices: NoticeList(
    items: [
      for (var i = 1; i <= 12; i++)
        NoticeListItems(
          id: 'notice-$i',
          title: 'Notice $i',
          source: 'Synthetic',
          category: 'academic',
          content: 'Body $i',
        ),
    ],
  ),
  genericSections: const [
    GenericSection(sectionId: 'extra', title: 'Extra', fields: []),
  ],
);

Widget app(
  LayoutMemory store, {
  double scale = 1,
  Brightness brightness = Brightness.light,
  String language = 'zh',
}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: Locale(language),
  theme: ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.teal,
      brightness: brightness,
    ),
  ),
  builder: (context, child) => MediaQuery(
    // These tests exercise card geometry, navigation and persistence. The
    // adaptive title intentionally scrolls continuously at narrow widths;
    // its movement/lifecycle are covered by adaptive_school_title_test.dart.
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(scale),
      disableAnimations: true,
    ),
    child: child!,
  ),
  home: EleconHomePage(
    loadSnapshot: () async => snapshot(),
    layoutStore: store,
  ),
);

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('half cards support large English text in $brightness', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = LayoutMemory();
      await tester.pumpWidget(
        app(store, scale: 2, brightness: brightness, language: 'en'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Notices'), findsOneWidget);
      expect(find.text('Notice 1'), findsOneWidget);
      expect(find.text('Notice 2'), findsNothing);
      await tester.tap(find.text('Notices'));
      await tester.pumpAndSettle();
      expect(find.text('Notice 2'), findsOneWidget);
      expect(find.text('Notices'), findsOneWidget);
      expect(store.values, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'real home visibility survives restart and restores the chosen size',
    (tester) async {
      final store = LayoutMemory();
      store.values['preview'] = HomeCardLayout(
        sizes: {'notice': HomeCardSize.compact},
      );
      await tester.pumpWidget(app(store));
      await tester.pumpAndSettle();
      expect(find.text('通知'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('home-layout-manage')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('home-card-visible:notice')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('home-card:notice')), findsNothing);
      expect(
        find.byKey(const ValueKey('home-card:generic:extra')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app(store));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('home-card:notice')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('home-layout-manage')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('home-card-visible:notice')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(find.text('通知'), findsOneWidget);
      expect(find.text('Notice 1'), findsNothing);
      expect(store.values['preview']!.sizes['notice'], HomeCardSize.compact);
      await tester.tap(find.byKey(const ValueKey('home-card-open:notice')));
      await tester.pumpAndSettle();
      expect(find.text('Notice 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('full preview clears when identity or data source changes', (
    tester,
  ) async {
    final session = SourceSession();
    addTearDown(session.dispose);
    await tester.pumpWidget(
      SessionScope(controller: session, child: app(LayoutMemory())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('home-card:notice')));
    await tester.pumpAndSettle();
    expect(find.text('查看全部（12）'), findsNothing);
    expect(find.text('Notice 1'), findsOneWidget);
    session.changeSource();
    await tester.pumpAndSettle();
    expect(find.text('Notice 1'), findsNothing);
    expect(find.text('数据来源或身份已变更，请返回首页刷新。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'real home offers summaries, icon mode, full data and persistent order',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = LayoutMemory();
      await tester.pumpWidget(app(store));
      await tester.pumpAndSettle();
      expect(find.text('Notice 1'), findsOneWidget);
      expect(find.text('Notice 2'), findsNothing);
      await tester.longPress(find.byKey(const ValueKey('home-card:notice')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('home-card:notice')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('home-card-size:compact')));
      await tester.pumpAndSettle();
      expect(find.text('Notice 1'), findsNothing);
      expect(store.values['preview']!.sizes['notice'], HomeCardSize.compact);
      await tester.tap(find.byKey(const ValueKey('home-card:notice')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('home-card-after:notice')));
      await tester.pumpAndSettle();
      expect(store.values['preview']!.order, ['generic:extra', 'notice']);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app(store));
      await tester.pumpAndSettle();
      expect(find.text('Notice 1'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('home-card-open:notice')));
      await tester.pumpAndSettle();
      expect(find.text('Notice 2'), findsOneWidget);
      expect(find.text('查看全部（12）'), findsNothing);
      await tester.ensureVisible(find.text('Notice 12'));
      await tester.tap(find.text('Notice 12'));
      await tester.pumpAndSettle();
      expect(find.text('Body 12'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  for (final width in [320.0, 900.0]) {
    testWidgets('compact real cards remain readable at $width and large text', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = LayoutMemory();
      store.values['preview'] = HomeCardLayout(
        sizes: {'notice': HomeCardSize.compact},
      );
      await tester.pumpWidget(app(store, scale: 2));
      await tester.pumpAndSettle();
      expect(find.text('Notice 1'), findsNothing);
      expect(find.byTooltip('通知'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.longPress(find.byKey(const ValueKey('home-card:notice')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
