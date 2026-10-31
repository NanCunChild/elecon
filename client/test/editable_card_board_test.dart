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
  Future<HomeCardLayout> load(String scopeId) async =>
      reads[scopeId]?.future ?? layouts[scopeId] ?? HomeCardLayout();
  @override
  Future<void> save(String scopeId, HomeCardLayout layout) async {
    if (fail) throw StateError('synthetic save failure');
    layouts[scopeId] = layout;
  }
}

List<HomeCardEntry> entries([
  List<String> ids = const ['notice', 'schedule'],
]) => [
  for (final id in ids)
    HomeCardEntry(id: id, label: id, builder: (_) => _CounterCard(id)),
];
Widget app(
  MemoryLayoutStore store, {
  String school = 'school-a',
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
  Widget build(BuildContext context) {
    final size = HomeCardPresentation.of(context);
    return SizedBox(
      height: switch (size) {
        HomeCardSize.compact => 90,
        HomeCardSize.regular => 110,
        HomeCardSize.expanded => 160,
      },
      child: Column(
        children: [
          Text('${widget.id}:${size.name}:$count'),
          TextButton(
            key: ValueKey('action:${widget.id}'),
            onPressed: () => setState(() => count++),
            child: const Text('business action'),
          ),
        ],
      ),
    );
  }
}

Future<void> edit(WidgetTester tester) async {
  await tester.longPress(card('notice'));
  await tester.pumpAndSettle();
}

void expectOrder(WidgetTester tester, String first, String second) => expect(
  tester.getTopLeft(card(first)).dy,
  lessThan(tester.getTopLeft(card(second)).dy),
);

void main() {
  testWidgets(
    'editing removes business keyboard focus and prevents activation',
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
                child: const Text('keyboard action'),
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(calls, 1);
      await edit(tester);
      focus.requestFocus();
      await tester.pump();
      expect(focus.hasFocus, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focus.hasFocus, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(calls, 1);
    },
  );

  testWidgets(
    'long press edits, absorbs business taps, and preserves state during reorder',
    (tester) async {
      final store = MemoryLayoutStore();
      await tester.pumpWidget(app(store));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('action:notice')));
      await tester.pump();
      await edit(tester);
      expect(find.text('完成'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('action:notice')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(find.text('notice:regular:1'), findsOneWidget);
      await tester.tap(control('after', 'notice'));
      await tester.pumpAndSettle();
      expectOrder(tester, 'schedule', 'notice');
      expect(find.text('notice:regular:1'), findsOneWidget);
      expect(store.layouts['school-a']!.order, ['schedule', 'notice']);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('action:notice')));
      await tester.pump();
      expect(find.text('notice:regular:2'), findsOneWidget);
    },
  );
  testWidgets('corner drag snaps size and survives remount and school switch', (
    tester,
  ) async {
    final store = MemoryLayoutStore();
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();
    await edit(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(control('resize', 'notice')),
    );
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-70, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('notice:compact:0'), findsOneWidget);
    expect(store.layouts['school-a']!.sizes['notice'], HomeCardSize.compact);
    expect(
      tester.getSize(card('notice')).width,
      lessThan(tester.getSize(card('schedule')).width),
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();
    expect(find.text('notice:compact:0'), findsOneWidget);
    await tester.pumpWidget(app(store, school: 'school-b'));
    await tester.pumpAndSettle();
    expect(find.text('notice:regular:0'), findsOneWidget);
    await tester.pumpWidget(app(store, school: 'school-a'));
    await tester.pumpAndSettle();
    expect(find.text('notice:compact:0'), findsOneWidget);
  });
  testWidgets('drag handle reorders without remounting the loaded child', (
    tester,
  ) async {
    final store = MemoryLayoutStore();
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('action:notice')));
    await edit(tester);
    await tester.drag(
      control('drag', 'notice'),
      tester.getCenter(card('schedule')) -
          tester.getCenter(control('drag', 'notice')),
    );
    await tester.pumpAndSettle();
    expectOrder(tester, 'schedule', 'notice');
    expect(find.text('notice:regular:1'), findsOneWidget);
  });
  testWidgets(
    'large text and narrow width stay readable without rewriting preferences',
    (tester) async {
      final store = MemoryLayoutStore();
      store.layouts['school-a'] = HomeCardLayout(
        sizes: {'notice': HomeCardSize.compact},
      );
      await tester.pumpWidget(app(store, scale: 1.5));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(card('notice')).width,
        tester.getSize(card('schedule')).width,
      );
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(app(store));
      await tester.pumpAndSettle();
      expect(tester.getSize(card('notice')).width, 320);
      await edit(tester);
      expect(tester.takeException(), isNull);
      expect(store.layouts['school-a']!.sizes['notice'], HomeCardSize.compact);
    },
  );
  testWidgets('late load cannot replace edits or new school layout', (
    tester,
  ) async {
    final store = MemoryLayoutStore();
    final late = Completer<HomeCardLayout>();
    store.reads['school-a'] = late;
    await tester.pumpWidget(app(store));
    await edit(tester);
    await tester.tap(control('after', 'notice'));
    await tester.pumpAndSettle();
    late.complete(HomeCardLayout(order: ['notice', 'schedule']));
    await tester.pumpAndSettle();
    expectOrder(tester, 'schedule', 'notice');
    final later = Completer<HomeCardLayout>();
    store.reads['school-c'] = later;
    await tester.pumpWidget(app(store, school: 'school-c'));
    await tester.pump();
    await tester.pumpWidget(app(store, school: 'school-b'));
    await tester.pumpAndSettle();
    later.complete(HomeCardLayout(order: ['schedule', 'notice']));
    await tester.pumpAndSettle();
    expectOrder(tester, 'notice', 'schedule');
  });
  testWidgets('failed save retains draft and can retry; reset persists', (
    tester,
  ) async {
    final store = MemoryLayoutStore()..fail = true;
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();
    await edit(tester);
    await tester.tap(control('after', 'notice'));
    await tester.pumpAndSettle();
    expect(find.text('布局暂未保存，请重试'), findsOneWidget);
    expectOrder(tester, 'schedule', 'notice');
    store.fail = false;
    await tester.tap(find.text('重试保存'));
    await tester.pumpAndSettle();
    expect(find.text('布局暂未保存，请重试'), findsNothing);
    expect(store.layouts['school-a']!.order, ['schedule', 'notice']);
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();
    expect(store.layouts['school-a']!.order, isEmpty);
    expectOrder(tester, 'notice', 'schedule');
  });
  testWidgets(
    'vertical resize works inside scrolling and cancellation restores size',
    (tester) async {
      final store = MemoryLayoutStore();
      await tester.pumpWidget(app(store));
      await tester.pumpAndSettle();
      await edit(tester);
      await tester.drag(control('resize', 'notice'), const Offset(0, -80));
      await tester.pumpAndSettle();
      expect(find.text('notice:compact:0'), findsOneWidget);
      final gesture = await tester.startGesture(
        tester.getCenter(control('resize', 'notice')),
      );
      await gesture.moveBy(const Offset(0, 80));
      await tester.pump();
      expect(find.text('notice:regular:0'), findsOneWidget);
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(find.text('notice:compact:0'), findsOneWidget);
      expect(store.layouts['school-a']!.sizes['notice'], HomeCardSize.compact);
    },
  );

  testWidgets('dragging near the viewport edge scrolls a long dashboard', (
    tester,
  ) async {
    final store = MemoryLayoutStore();
    await tester.pumpWidget(
      app(
        store,
        cards: entries(['notice', 'schedule', 'library', 'grades', 'extra']),
      ),
    );
    await tester.pumpAndSettle();
    await edit(tester);
    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    final start = tester.getCenter(control('drag', 'notice'));
    final gesture = await tester.startGesture(start);
    await gesture.moveTo(Offset(start.dx, 580));
    await tester.pump(const Duration(milliseconds: 300));
    expect(scrollable.position.pixels, greaterThan(0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'finite size picker and temporarily missing cards retain preferences',
    (tester) async {
      final store = MemoryLayoutStore();
      await tester.pumpWidget(app(store));
      await tester.pumpAndSettle();
      await edit(tester);
      await tester.tap(control('size', 'notice'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate(
          (widget) =>
              widget is CheckedPopupMenuItem<HomeCardSize> &&
              widget.value == HomeCardSize.expanded,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('notice:expanded:0'), findsOneWidget);
      await tester.pumpWidget(app(store, cards: entries(['schedule'])));
      await tester.pumpAndSettle();
      await tester.pumpWidget(app(store));
      await tester.pumpAndSettle();
      expect(find.text('notice:expanded:0'), findsOneWidget);
      await tester.pumpWidget(
        app(
          store,
          cards: [
            HomeCardEntry(
              id: 'controls',
              label: 'controls',
              builder: (_) => const Text('body'),
              sizes: const [HomeCardSize.regular],
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(control('resize', 'controls'), findsNothing);
      expect(control('size', 'controls'), findsNothing);
    },
  );
}
