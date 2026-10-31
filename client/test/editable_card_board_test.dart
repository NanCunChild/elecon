import 'dart:async';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/ui/home/card_layout.dart';
import 'package:elecon/ui/home/card_layout_store.dart';
import 'package:elecon/ui/home/editable_card_board.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryLayoutStore extends CardLayoutStore {
  final layouts = <String, HomeCardLayout>{};
  final reads = <String, Completer<HomeCardLayout>>{};
  bool fail = false;
  @override
  Future<HomeCardLayout> load(String id) async =>
      reads[id]?.future ?? layouts[id] ?? HomeCardLayout();
  @override
  Future<void> save(String id, HomeCardLayout layout) async {
    if (fail) throw StateError('synthetic failure');
    layouts[id] = layout;
  }
}

List<HomeCardEntry> entries([
  List<String> ids = const ['notice', 'schedule'],
]) => [
  for (final id in ids)
    HomeCardEntry(
      id: id,
      label: id,
      defaultSize: HomeCardSize.expanded,
      builder: (_) => _CounterCard(id),
    ),
];
Widget app(
  MemoryLayoutStore store, {
  String school = 'a',
  List<HomeCardEntry>? cards,
  double scale = 1,
}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('zh'),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: EditableCardBoard(
        scopeId: school,
        cards: cards ?? entries(),
        store: store,
      ),
    ),
  ),
);
Finder card(String id) => find.byKey(ValueKey('home-card:$id'));
Finder control(String kind, String id) =>
    find.byKey(ValueKey('home-card-$kind:$id'));

class _CounterCard extends StatefulWidget {
  const _CounterCard(this.id);
  final String id;
  @override
  State<_CounterCard> createState() => _CounterCardState();
}

class _CounterCardState extends State<_CounterCard> {
  int count = 0;
  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 160),
    child: Column(
      children: [
        Text('${widget.id}:${HomeCardPresentation.of(context).name}:$count'),
        TextButton(
          key: ValueKey('action:${widget.id}'),
          onPressed: () => setState(() => count++),
          child: const Text('business action'),
        ),
      ],
    ),
  );
}

Future<void> edit(WidgetTester tester) async {
  await tester.longPress(card('notice'));
  await tester.pumpAndSettle();
}

Future<void> choose(WidgetTester tester, String id, String action) async {
  await tester.tap(card(id));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.byKey(ValueKey(action)));
  await tester.tap(find.byKey(ValueKey(action)));
  await tester.pumpAndSettle();
}

Future<TestGesture> pickup(WidgetTester tester, String id) async {
  final g = await tester.startGesture(
    tester.getTopLeft(card(id)) + const Offset(20, 20),
  );
  await tester.pump(const Duration(milliseconds: 600));
  return g;
}

void order(WidgetTester tester, String first, String second) => expect(
  tester.getTopLeft(card(first)).dy,
  lessThan(tester.getTopLeft(card(second)).dy),
);
void main() {
  testWidgets('icon centre long press picks up and reorders horizontally', (
    tester,
  ) async {
    final store = MemoryLayoutStore();
    store.layouts['a'] = HomeCardLayout(
      sizes: {'notice': HomeCardSize.compact, 'schedule': HomeCardSize.compact},
    );
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(control('open', 'notice')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('完成'), findsOneWidget);
    await gesture.moveTo(tester.getCenter(control('open', 'schedule')));
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      tester.getTopLeft(card('schedule')).dx,
      lessThan(tester.getTopLeft(card('notice')).dx),
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(store.layouts['a']!.order, ['schedule', 'notice']);
  });

  testWidgets(
    'one long press moves neighbours before release and saves only on drop',
    (tester) async {
      final store = MemoryLayoutStore();
      await tester.pumpWidget(app(store));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('action:notice')));
      final g = await pickup(tester, 'notice');
      expect(find.text('完成'), findsOneWidget);
      await g.moveTo(tester.getCenter(card('schedule')));
      await tester.pump(const Duration(milliseconds: 160));
      await tester.pump(const Duration(milliseconds: 250));
      order(tester, 'schedule', 'notice');
      expect(store.layouts, isEmpty);
      await tester.pump(const Duration(milliseconds: 500));
      order(tester, 'schedule', 'notice');
      await g.up();
      await tester.pumpAndSettle();
      expect(store.layouts['a']!.order, ['schedule', 'notice']);
      expect(find.text('notice:expanded:1'), findsOneWidget);
      expect(control('resize', 'notice'), findsNothing);
      expect(control('drag', 'notice'), findsNothing);
    },
  );
  testWidgets('cancel restores order without saving', (tester) async {
    final store = MemoryLayoutStore();
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();
    final g = await pickup(tester, 'notice');
    await g.moveTo(tester.getCenter(card('schedule')));
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pump(const Duration(milliseconds: 250));
    order(tester, 'schedule', 'notice');
    await g.cancel();
    await tester.pumpAndSettle();
    order(tester, 'notice', 'schedule');
    expect(store.layouts, isEmpty);
  });
  testWidgets(
    'editing excludes business keyboard focus and permits size menu',
    (tester) async {
      final store = MemoryLayoutStore();
      final focus = FocusNode();
      addTearDown(focus.dispose);
      var calls = 0;
      await tester.pumpWidget(
        app(
          store,
          cards: [
            HomeCardEntry(
              id: 'notice',
              label: 'notice',
              builder: (_) => TextButton(
                focusNode: focus,
                onPressed: () => calls++,
                child: const Text('action'),
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(calls, 1);
      await edit(tester);
      focus.requestFocus();
      await tester.pump();
      expect(focus.hasFocus, isFalse);
      await choose(tester, 'notice', 'home-card-size:compact');
      expect(calls, 1);
      expect(store.layouts['a']!.sizes['notice'], HomeCardSize.compact);
    },
  );
  testWidgets(
    'icon opens same child and collapses without rewriting size; school isolation',
    (tester) async {
      final store = MemoryLayoutStore();
      await tester.pumpWidget(app(store));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('action:notice')));
      await edit(tester);
      await choose(tester, 'notice', 'home-card-size:compact');
      expect(find.text('notice:compact:1'), findsNothing);
      expect(find.byTooltip('notice'), findsOneWidget);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await tester.tap(control('open', 'notice'));
      await tester.pumpAndSettle();
      expect(find.text('notice:expanded:1'), findsOneWidget);
      await tester.tap(control('close', 'notice'));
      await tester.pumpAndSettle();
      expect(store.layouts['a']!.sizes['notice'], HomeCardSize.compact);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app(store));
      await tester.pumpAndSettle();
      expect(find.byTooltip('notice'), findsOneWidget);
      await tester.pumpWidget(app(store, school: 'b'));
      await tester.pumpAndSettle();
      expect(find.text('notice:expanded:0'), findsOneWidget);
      await tester.pumpWidget(app(store));
      await tester.pumpAndSettle();
      expect(find.byTooltip('notice'), findsOneWidget);
    },
  );
  testWidgets('phone shows quarter half full; large text retains preferences', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = MemoryLayoutStore();
    store.layouts['a'] = HomeCardLayout(
      sizes: {
        'notice': HomeCardSize.compact,
        'schedule': HomeCardSize.regular,
        'library': HomeCardSize.expanded,
      },
    );
    await tester.pumpWidget(
      app(store, cards: entries(['notice', 'schedule', 'library'])),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(card('notice')).width, 91);
    expect(tester.getSize(card('schedule')).width, 194);
    expect(tester.getSize(card('library')).width, 400);
    await tester.pumpWidget(app(store, scale: 2));
    await tester.pumpAndSettle();
    expect(tester.getSize(card('schedule')).width, 400);
    expect(tester.getSize(card('notice')).width, 91);
    expect(store.layouts['a']!.sizes['schedule'], HomeCardSize.regular);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'late reads and old scope menus cannot overwrite current layout',
    (tester) async {
      final store = MemoryLayoutStore();
      final late = Completer<HomeCardLayout>();
      store.reads['a'] = late;
      await tester.pumpWidget(app(store));
      await edit(tester);
      await choose(tester, 'notice', 'home-card-after:notice');
      late.complete(HomeCardLayout(order: ['notice', 'schedule']));
      await tester.pumpAndSettle();
      order(tester, 'schedule', 'notice');
      await tester.tap(card('notice'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(app(store, school: 'b'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('home-card-size:compact')));
      await tester.pumpAndSettle();
      expect(store.layouts.containsKey('b'), isFalse);
      order(tester, 'notice', 'schedule');
    },
  );
  testWidgets('failed save retains draft; retry and reset persist', (
    tester,
  ) async {
    final store = MemoryLayoutStore()..fail = true;
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();
    await edit(tester);
    await choose(tester, 'notice', 'home-card-after:notice');
    expect(find.text('布局暂未保存，请重试'), findsOneWidget);
    order(tester, 'schedule', 'notice');
    store.fail = false;
    await tester.tap(find.text('重试保存'));
    await tester.pumpAndSettle();
    expect(find.text('布局暂未保存，请重试'), findsNothing);
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();
    expect(store.layouts['a']!.order, isEmpty);
  });
  testWidgets('edge dragging scrolls a long dashboard', (tester) async {
    final store = MemoryLayoutStore();
    await tester.pumpWidget(
      app(
        store,
        cards: entries(['notice', 'schedule', 'library', 'grades', 'extra']),
      ),
    );
    await tester.pumpAndSettle();
    final g = await pickup(tester, 'notice');
    await g.moveTo(const Offset(200, 580));
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .pixels,
      greaterThan(0),
    );
    await g.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('temporarily missing cards retain preferences', (tester) async {
    final store = MemoryLayoutStore();
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();
    await edit(tester);
    await choose(tester, 'notice', 'home-card-size:regular');
    await tester.pumpWidget(app(store, cards: entries(['schedule'])));
    await tester.pumpAndSettle();
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();
    expect(find.text('notice:regular:0'), findsOneWidget);
  });
}
