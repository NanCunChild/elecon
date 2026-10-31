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
      for (var i = 1; i <= 8; i++)
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

Widget app(LayoutMemory store, {double scale = 1}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('zh'),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: EleconHomePage(
    loadSnapshot: () async => snapshot(),
    layoutStore: store,
  ),
);

void main() {
  testWidgets('full preview clears when identity or data source changes', (
    tester,
  ) async {
    final session = SourceSession();
    addTearDown(session.dispose);
    await tester.pumpWidget(
      SessionScope(controller: session, child: app(LayoutMemory())),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('查看全部（8）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看全部（8）'));
    await tester.pumpAndSettle();
    expect(find.text('Notice 1'), findsOneWidget);
    session.changeSource();
    await tester.pumpAndSettle();
    expect(find.text('Notice 1'), findsNothing);
    expect(find.text('数据来源或身份已变更，请返回首页刷新。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('real home long press and resize retain layout across remount', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = LayoutMemory();
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();
    expect(find.text('Notice 3'), findsOneWidget);
    expect(find.text('Notice 4'), findsNothing);
    await tester.longPress(find.byKey(const ValueKey('home-card:notice')));
    await tester.pumpAndSettle();
    expect(find.text('完成'), findsOneWidget);
    await tester.tap(find.text('Notice 1'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('通知详情'), findsNothing);
    await tester.drag(
      find.byKey(const ValueKey('home-card-resize:notice')),
      const Offset(-80, -80),
    );
    await tester.pumpAndSettle();
    expect(store.values['preview']!.sizes['notice'], HomeCardSize.compact);
    expect(find.text('Notice 2'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('home-card-after:notice')));
    await tester.pumpAndSettle();
    expect(store.values['preview']!.order, ['generic:extra', 'notice']);
    await tester.tap(find.byKey(const ValueKey('home-layout-edit')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();
    expect(find.text('Notice 2'), findsNothing);
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('home-card:generic:extra')))
          .dy,
      lessThan(
        tester.getTopLeft(find.byKey(const ValueKey('home-card:notice'))).dy,
      ),
    );
    await tester.tap(find.text('查看全部（8）'));
    await tester.pumpAndSettle();
    expect(find.text('Notice 8'), findsOneWidget);
    await tester.tap(find.text('Notice 8'));
    await tester.pumpAndSettle();
    expect(find.text('Body 8'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
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
      expect(find.text('Notice 1'), findsOneWidget);
      expect(find.text('Notice 2'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.longPress(find.byKey(const ValueKey('home-card:notice')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
