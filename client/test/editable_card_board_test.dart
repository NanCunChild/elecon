import 'dart:async';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/ui/home/card_layout.dart';
import 'package:elecon/ui/home/section_card.dart';
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
  TextDirection direction = TextDirection.ltr,
}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('zh'),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: Directionality(textDirection: direction, child: child!),
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
        Text('preset:${widget.id}:${HomeCardPresentation.presetOf(context)}'),
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
  testWidgets('dropping unequal expanded cards preserves the previewed order', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = MemoryLayoutStore();
    await tester.pumpWidget(
      app(
        store,
        cards: [
          for (final (id, height) in [('notice', 120.0), ('schedule', 375.0)])
            HomeCardEntry(
              id: id,
              label: id,
              defaultSize: HomeCardSize.expanded,
              builder: (_) => SizedBox(height: height),
            ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    final gesture = await pickup(tester, 'notice');
    await gesture.moveTo(tester.getCenter(card('schedule')));
    await tester.pump(const Duration(milliseconds: 180));
    await tester.pump(const Duration(milliseconds: 250));
    order(tester, 'schedule', 'notice');
    await gesture.up();
    await tester.pumpAndSettle();
    order(tester, 'schedule', 'notice');
    expect(store.layouts['a']!.order, ['schedule', 'notice']);
  });

  testWidgets(
    'bounded full-width cards compact mixed rows, drag and restore without overlap',
    (tester) async {
      tester.view.physicalSize = const Size(400, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final height = ValueNotifier(73.0);
      addTearDown(height.dispose);
      final store = MemoryLayoutStore();
      store.layouts['a'] = HomeCardLayout(
        sizes: {
          for (final id in ['a', 'b', 'c', 'd']) id: HomeCardSize.compact,
        },
      );
      final cards = [
        HomeCardEntry(
          id: 'first',
          label: 'First',
          defaultSize: HomeCardSize.expanded,
          builder: (_) => ValueListenableBuilder<double>(
            valueListenable: height,
            builder: (_, value, _) => SizedBox(height: value),
          ),
        ),
        HomeCardEntry(
          id: 'summary',
          label: 'Summary',
          builder: (_) => const SectionCard(
            title: 'Summary',
            summary: CardSummary('Synthetic summary'),
            child: Text('Full details'),
          ),
        ),
        ...entries(['a', 'b', 'c', 'd']),
        HomeCardEntry(
          id: 'last',
          label: 'Last',
          defaultSize: HomeCardSize.expanded,
          builder: (_) => const SizedBox(height: 127),
        ),
      ];
      Rect slot(String id) => tester.getRect(control('slot', id));
      void checkGeometry() {
        // ADR-086: full-width home entries keep a finite preview even when
        // their underlying content changes height.
        expect(slot('first').height, 280);
        expect(slot('summary').top - slot('first').bottom, 12);
        expect(slot('last').top - slot('summary').bottom, 12);
        expect(slot('last').height, 280);
        expect(slot('a').height * 2 + 12, slot('summary').height);
        for (var i = 0; i < cards.length; i++) {
          for (var j = i + 1; j < cards.length; j++) {
            expect(
              slot(cards[i].id).overlaps(slot(cards[j].id)),
              isFalse,
              reason: '${cards[i].id} overlaps ${cards[j].id}',
            );
          }
        }
      }

      await tester.pumpWidget(app(store, cards: cards));
      await tester.pumpAndSettle();
      checkGeometry();
      final gesture = await tester.startGesture(
        tester.getCenter(control('open', 'a')),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(tester.getCenter(control('open', 'b')));
      await tester.pump(const Duration(milliseconds: 180));
      await tester.pump(const Duration(milliseconds: 250));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(store.layouts['a']!.positions['a']!.column, 3);
      expect(store.layouts['a']!.positions['a']!.row, 3);
      checkGeometry();
      height.value = 1200;
      await tester.pumpAndSettle();
      checkGeometry();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app(store, cards: cards));
      await tester.pumpAndSettle();
      expect(store.layouts['a']!.positions['a'], const HomeCardPosition(3, 3));
      checkGeometry();
      expect(tester.takeException(), isNull);
    },
  );

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
      await tester.tap(find.byKey(const ValueKey('home-layout-manage')));
      await tester.pump();
      expect(find.byType(SwitchListTile), findsNothing);
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
    'icon opens feature page and returns without rewriting size; school isolation',
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
      await tester.tap(find.byType(BackButton));
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
    expect(tester.getSize(control('open', 'notice')).width, 91);
    expect(tester.getSize(control('open', 'notice')).height, 91);
    expect(
      find.descendant(of: card('notice'), matching: find.text('notice')),
      findsOneWidget,
    );
    expect(tester.getSize(card('schedule')).width, 194);
    expect(tester.getSize(card('library')).width, 400);
    await tester.pumpWidget(app(store, scale: 2));
    await tester.pumpAndSettle();
    expect(tester.getSize(card('schedule')).width, 194);
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
    await tester.tap(find.byKey(const ValueKey('home-layout-manage')));
    await tester.pumpAndSettle();
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
  testWidgets('quarter tile opens from its edge and exposes a visible label', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = MemoryLayoutStore();
    store.layouts['a'] = HomeCardLayout(
      sizes: {'notice': HomeCardSize.compact},
    );
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();
    expect(find.text('notice'), findsOneWidget);
    expect(
      tester.getSize(control('open', 'notice')).width,
      tester.getSize(card('notice')).width,
    );
    await tester.tapAt(
      tester.getTopLeft(control('open', 'notice')) + const Offset(4, 50),
    );
    await tester.pumpAndSettle();
    expect(find.text('notice:expanded:0'), findsOneWidget);
    expect(store.layouts['a']!.sizes['notice'], HomeCardSize.compact);
  });

  testWidgets('all cards can be hidden, reopened after restart and reset', (
    tester,
  ) async {
    final store = MemoryLayoutStore();
    store.layouts['a'] = HomeCardLayout(
      order: ['schedule', 'notice'],
      sizes: {'notice': HomeCardSize.compact},
      presets: {'notice': 'future-style'},
    );
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('home-layout-manage')));
    await tester.pumpAndSettle();
    await tester.tap(control('visible', 'notice'));
    await tester.pumpAndSettle();
    await tester.tap(control('visible', 'schedule'));
    await tester.pumpAndSettle();
    expect(store.layouts['a']!.hidden, {'notice', 'schedule'});
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(card('notice'), findsNothing);
    expect(card('schedule'), findsNothing);
    expect(find.byType(_CounterCard, skipOffstage: false), findsNothing);
    expect(find.text('还没有显示的卡片，可在“主页展示”中添加。'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();
    expect(card('notice'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('home-layout-manage')));
    await tester.pumpAndSettle();
    await tester.tap(control('visible', 'notice'));
    await tester.pumpAndSettle();
    expect(store.layouts['a']!.hidden, {'schedule'});
    expect(store.layouts['a']!.sizes['notice'], HomeCardSize.compact);
    expect(store.layouts['a']!.presets['notice'], 'future-style');
    expect(store.layouts['a']!.order, ['schedule', 'notice']);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('notice'), findsOneWidget);
    await tester.pumpWidget(app(store, school: 'b'));
    await tester.pumpAndSettle();
    expect(card('schedule'), findsOneWidget);
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();
    expect(card('schedule'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('home-layout-manage')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(card('schedule'), findsOneWidget);
    expect(store.layouts['a']!.hidden, isEmpty);
    expect(store.layouts['a']!.presets, isEmpty);
    expect(store.layouts['a']!.sizes, isEmpty);
    expect(store.layouts['a']!.order, isEmpty);
  });

  testWidgets(
    'hidden card menu preserves draft on save failure and can retry',
    (tester) async {
      final store = MemoryLayoutStore()..fail = true;
      await tester.pumpWidget(app(store));
      await tester.pumpAndSettle();
      await edit(tester);
      await tester.tap(card('notice'));
      await tester.pumpAndSettle();
      expect(find.text('展示样式'), findsNothing);
      await tester.ensureVisible(control('hide', 'notice'));
      await tester.tap(control('hide', 'notice'));
      await tester.pumpAndSettle();
      expect(card('notice'), findsNothing);
      expect(find.text('布局暂未保存，请重试'), findsOneWidget);
      store.fail = false;
      await tester.tap(find.text('重试保存'));
      await tester.pumpAndSettle();
      expect(store.layouts['a']!.hidden, {'notice'});
      expect(find.text('布局暂未保存，请重试'), findsNothing);
    },
  );

  testWidgets('old school visibility sheet cannot edit a new school', (
    tester,
  ) async {
    final store = MemoryLayoutStore();
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('home-layout-manage')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(app(store, school: 'b'));
    await tester.pumpAndSettle();
    await tester.tap(control('visible', 'notice'));
    await tester.pumpAndSettle();
    expect(store.layouts, isEmpty);
    expect(card('notice'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing);
  });

  testWidgets(
    'registered presets share card state and fall back without losing preferences',
    (tester) async {
      final store = MemoryLayoutStore();
      final configured = [
        HomeCardEntry(
          id: 'notice',
          label: 'notice',
          defaultSize: HomeCardSize.expanded,
          presets: const [
            HomeCardPreset(id: 'preview', label: 'Synthetic preview'),
          ],
          builder: (_) => const _CounterCard('notice'),
        ),
      ];
      await tester.pumpWidget(app(store, cards: configured));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('action:notice')));
      await edit(tester);
      await choose(tester, 'notice', 'home-card-preset:preview');
      expect(find.text('preset:notice:preview'), findsOneWidget);
      expect(find.text('notice:expanded:1'), findsOneWidget);
      expect(store.layouts['a']!.presets['notice'], 'preview');
      await choose(tester, 'notice', 'home-card-size:compact');
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await tester.tap(control('open', 'notice'));
      await tester.pumpAndSettle();
      expect(find.text('preset:notice:preview'), findsOneWidget);
      expect(find.text('notice:expanded:1'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await edit(tester);
      await choose(tester, 'notice', 'home-card-size:expanded');
      await tester.pumpWidget(app(store));
      await tester.pumpAndSettle();
      expect(find.text('preset:notice:standard'), findsOneWidget);
      expect(store.layouts['a']!.presets['notice'], 'preview');
      await tester.pumpWidget(app(store, cards: configured));
      await tester.pumpAndSettle();
      expect(find.text('preset:notice:preview'), findsOneWidget);
      expect(find.text('notice:expanded:1'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app(store, cards: configured));
      await tester.pumpAndSettle();
      await edit(tester);
      await choose(tester, 'notice', 'home-card-size:compact');
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await tester.tap(control('open', 'notice'));
      await tester.pumpAndSettle();
      expect(find.text('preset:notice:preview'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await edit(tester);
      await choose(tester, 'notice', 'home-card-preset:standard');
      expect(store.layouts['a']!.presets, isEmpty);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await tester.tap(control('open', 'notice'));
      await tester.pumpAndSettle();
      expect(find.text('preset:notice:standard'), findsOneWidget);
    },
  );
  testWidgets(
    'real summary equals four icons including gaps, with staggered cells',
    (tester) async {
      tester.view.physicalSize = const Size(400, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = MemoryLayoutStore();
      store.layouts['a'] = HomeCardLayout(
        sizes: {
          for (final id in ['a', 'b', 'c', 'd']) id: HomeCardSize.compact,
        },
      );
      await tester.pumpWidget(
        app(
          store,
          cards: [
            HomeCardEntry(
              id: 'summary',
              label: 'Summary',
              builder: (_) => const SectionCard(
                title: 'Summary',
                summary: CardSummary(
                  'Synthetic summary',
                  detail: 'Synthetic source',
                ),
                child: Text('Full details'),
              ),
            ),
            ...entries(['a', 'b', 'c', 'd']),
          ],
        ),
      );
      await tester.pumpAndSettle();
      Rect slot(String id) => tester.getRect(control('slot', id));
      final smallGroup = slot('a').expandToInclude(slot('d'));
      expect(smallGroup.size, slot('summary').size);
      expect(slot('a').top, slot('summary').top);
      expect(slot('d').bottom, slot('summary').bottom);
      expect(slot('c').left, slot('a').left);
      expect(slot('c').top - slot('a').bottom, 12);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('empty-cell drop settles upward and cancelled drag rolls back', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = MemoryLayoutStore();
    store.layouts['a'] = HomeCardLayout(
      sizes: {'notice': HomeCardSize.compact, 'schedule': HomeCardSize.compact},
    );
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();
    final origin = tester.getTopLeft(card('notice'));
    final small = tester.getSize(card('notice'));
    final delta = Offset(3 * (small.width + 12), 2 * (small.height + 12));
    final gesture = await tester.startGesture(
      tester.getCenter(control('open', 'notice')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(delta);
    await tester.pump(const Duration(milliseconds: 180));
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.getTopLeft(card('notice')), origin + delta);
    expect(store.layouts['a']!.positions, isEmpty);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      store.layouts['a']!.positions['notice'],
      const HomeCardPosition(3, 0),
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(card('notice')), origin + Offset(delta.dx, 0));
    final cancel = await tester.startGesture(
      tester.getCenter(control('open', 'notice')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await cancel.moveBy(-delta);
    await tester.pump(const Duration(milliseconds: 180));
    await tester.pump(const Duration(milliseconds: 250));
    await cancel.cancel();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(card('notice')), origin + Offset(delta.dx, 0));
    expect(
      store.layouts['a']!.positions['notice'],
      const HomeCardPosition(3, 0),
    );
    await choose(tester, 'notice', 'home-card-grid:up');
    expect(
      store.layouts['a']!.positions['notice'],
      const HomeCardPosition(3, 0),
    );
  });
  testWidgets('RTL drag mirrors columns while preserving logical coordinates', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = MemoryLayoutStore();
    store.layouts['a'] = HomeCardLayout(
      sizes: {'notice': HomeCardSize.compact, 'schedule': HomeCardSize.compact},
    );
    await tester.pumpWidget(app(store, direction: TextDirection.rtl));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(card('notice')).dx,
      greaterThan(tester.getTopLeft(card('schedule')).dx),
    );
    final start = tester.getCenter(control('open', 'notice'));
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(-206, 103));
    await tester.pump(const Duration(milliseconds: 180));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      store.layouts['a']!.positions['notice'],
      const HomeCardPosition(2, 0),
    );
    await choose(tester, 'notice', 'home-card-grid:left');
    expect(
      store.layouts['a']!.positions['notice'],
      const HomeCardPosition(3, 0),
    );
    await tester.pumpWidget(app(store, direction: TextDirection.ltr));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(card('notice')).dx, 309);
  });
  testWidgets('large-text toolbar does not move the grid on pickup', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(288, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = MemoryLayoutStore();
    await tester.pumpWidget(app(store, scale: 2));
    await tester.pumpAndSettle();
    final before = tester.getTopLeft(card('notice'));
    final g = await pickup(tester, 'notice');
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(card('notice')), before);
    await g.cancel();
    await tester.pumpAndSettle();
  });
}
