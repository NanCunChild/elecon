import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/ui/home/capability_source.dart';
import 'package:elecon/ui/home/card_layout.dart';
import 'package:elecon/ui/home/models.dart';
import 'package:elecon/ui/home/notice_detail_page.dart';
import 'package:elecon/ui/home/notice_summary.dart';
import 'package:elecon/ui/home/result_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const notices = [
  NoticeListItems(
    id: 'first',
    title: 'First synthetic notice',
    category: 'academic',
    source: 'Synthetic source',
    summary: 'A concise synthetic summary, preserved separately from the body.',
    content: 'The complete synthetic notice body.',
    publishedAt: '2026-11-05T08:00:00Z',
  ),
  NoticeListItems(
    id: 'second',
    title: 'Second synthetic notice',
    category: 'academic',
    source: 'Synthetic source',
    summary: 'Another summary.',
    content: 'Another complete body.',
  ),
  NoticeListItems(
    id: 'third',
    title: 'Third synthetic notice',
    category: 'academic',
    source: 'Synthetic source',
  ),
];

Widget app(
  Widget child, {
  double scale = 1,
  bool reducedMotion = false,
  bool accessible = false,
  bool ticker = true,
  Brightness brightness = Brightness.light,
  String locale = 'en',
}) => MaterialApp(
  locale: Locale(locale),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: ThemeData(brightness: brightness),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(scale),
      disableAnimations: reducedMotion,
      accessibleNavigation: accessible,
    ),
    child: child!,
  ),
  home: Scaffold(
    body: TickerMode(enabled: ticker, child: child),
  ),
);

Widget summary({List<NoticeListItems> items = notices}) =>
    SizedBox(width: 320, height: 180, child: NoticeSummary(items: items));

void main() {
  testWidgets(
    'rotates summaries, manual next pauses, explicit resume restarts',
    (tester) async {
      await tester.pumpWidget(app(summary()));
      expect(find.text(notices.first.summary!), findsOneWidget);
      await tester.pump(const Duration(seconds: 8));
      expect(find.text(notices[1].title), findsOneWidget);
      await tester.tap(find.byTooltip('Next notice'));
      await tester.pump();
      expect(find.text(notices[2].title), findsOneWidget);
      await tester.pump(const Duration(seconds: 16));
      expect(find.text(notices[2].title), findsOneWidget);
      await tester.tap(find.byTooltip('Resume notices'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 8));
      expect(find.text(notices[0].title), findsOneWidget);
      await tester.tap(find.byTooltip('Pause notices'));
      await tester.pump(const Duration(seconds: 16));
      expect(find.text(notices[0].title), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final mode in ['reduced', 'accessible', 'hidden', 'background']) {
    testWidgets('$mode pauses rotation without preventing explicit next', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          summary(),
          reducedMotion: mode == 'reduced',
          accessible: mode == 'accessible',
          ticker: mode != 'hidden',
        ),
      );
      if (mode == 'background') {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
      }
      await tester.pump(const Duration(seconds: 24));
      expect(find.text(notices[0].title), findsOneWidget);
      if (mode == 'background') {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
      }
      await tester.tap(find.byTooltip('Next notice'));
      await tester.pump();
      expect(find.text(notices[1].title), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('offscreen preview pauses and resumes when scrolled into view', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      app(
        SingleChildScrollView(
          controller: scroll,
          child: Column(children: [summary(), const SizedBox(height: 2000)]),
        ),
      ),
    );
    scroll.jumpTo(900);
    await tester.pump();
    await tester.pump(const Duration(seconds: 16));
    expect(find.text(notices.first.title), findsOneWidget);
    scroll.jumpTo(0);
    await tester.pump();
    await tester.pump(const Duration(seconds: 8));
    expect(find.text(notices[1].title), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('updates preserve notice ID; source changes reset rotation', (
    tester,
  ) async {
    Widget bound(String package, List<NoticeListItems> items) => app(
      CapabilitySourceScope(
        source: CapabilitySource(
          packageId: package,
          digest: 'synthetic-digest',
        ),
        child: summary(items: items),
      ),
    );
    await tester.pumpWidget(bound('source-a', notices));
    await tester.pump(const Duration(seconds: 8));
    expect(find.text(notices[1].title), findsOneWidget);
    await tester.pumpWidget(bound('source-a', notices.reversed.toList()));
    expect(find.text(notices[1].title), findsOneWidget);
    await tester.pumpWidget(bound('source-b', notices));
    expect(find.text(notices[0].title), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'preview opens that notice and preserves its source and full body',
    (tester) async {
      var listOpens = 0;
      const source = CapabilitySource(
        packageId: 'source-a',
        digest: 'digest-a',
      );
      await tester.pumpWidget(
        app(
          CapabilitySourceScope(
            source: source,
            child: HomeCardPresentation(
              size: HomeCardSize.expanded,
              previewHeight: 280,
              onOpen: () => listOpens++,
              child: const NoticeCard(NoticeList(items: notices)),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('notice-summary-first')));
      await tester.pumpAndSettle();
      expect(listOpens, 0);
      final detail = tester.widget<NoticeDetailPage>(
        find.byType(NoticeDetailPage),
      );
      expect(detail.source, source);
      expect(find.text(notices.first.content!), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Notices'));
      await tester.pump();
      expect(listOpens, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final (width, height, scale, locale, brightness) in [
    (140.0, 140.0, 2.0, 'zh', Brightness.light),
    (140.0, 220.0, 1.0, 'en', Brightness.dark),
    (320.0, 280.0, 2.0, 'fa', Brightness.dark),
    (600.0, 280.0, 1.0, 'en', Brightness.light),
  ]) {
    testWidgets('bounded preview at $width / $height / $scale / $locale', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          SizedBox(
            width: width,
            height: height,
            child: HomeCardPresentation(
              size: HomeCardSize.regular,
              previewHeight: height,
              onOpen: () {},
              child: const NoticeCard(NoticeList(items: notices)),
            ),
          ),
          scale: scale,
          locale: locale,
          brightness: brightness,
        ),
      );
      expect(tester.takeException(), isNull);
      final title = tester.widget<Text>(find.text(notices.first.title));
      expect(title.maxLines, inInclusiveRange(1, 2));
      expect(title.overflow, TextOverflow.ellipsis);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('list limits summaries while preserving full detail content', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        const SingleChildScrollView(
          child: NoticeCard(NoticeList(items: notices)),
        ),
      ),
    );
    final row = tester.widget<ListTile>(find.byType(ListTile).first);
    expect((row.title as Text).maxLines, 2);
    final metadata = find.descendant(
      of: find.byType(ListTile).first,
      matching: find.byType(Text),
    );
    expect(
      tester.widgetList<Text>(metadata).every((text) => text.maxLines == 2),
      isTrue,
    );
    expect(find.text(notices.first.summary!), findsOneWidget);
    await tester.tap(find.text(notices.first.title));
    await tester.pumpAndSettle();
    expect(find.text(notices.first.content!), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
