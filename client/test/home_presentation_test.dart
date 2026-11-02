import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/ui/home/display_date.dart';
import 'package:elecon/ui/home/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget app(Widget home, {double textScale = 1, String language = 'zh'}) =>
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: Locale(language),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: home,
    );

void main() {
  test('UTC and offset timestamps display the local date and minute', () {
    // Run in a non-UTC timezone too: the UTC representation may be yesterday.
    final local = DateTime(2026, 1, 1, 0, 5, 59);
    final utc = local.toUtc();
    final offset =
        '${utc.add(const Duration(hours: 9)).toIso8601String().replaceFirst('Z', '')}+09:00';
    for (final value in [local, utc, DateTime.parse(offset)]) {
      expect(formatLocalDate(value), '2026-01-01');
      expect(formatLocalDateTime(value), '2026-01-01 00:05');
    }
  });

  test(
    'freshness labels respect minute, hour and strict three-day boundary',
    () async {
      final now = DateTime.utc(2026, 11, 2, 12);
      for (final language in ['zh', 'en']) {
        final l10n = await AppLocalizations.delegate.load(Locale(language));
        String ago(Duration age) =>
            formatUpdateTime(now.subtract(age), l10n, now: now);
        expect(ago(Duration.zero), l10n.homeTimeJustNow);
        expect(ago(const Duration(seconds: 59)), l10n.homeTimeJustNow);
        expect(ago(const Duration(minutes: 1)), l10n.homeTimeMinutesAgo(1));
        expect(ago(const Duration(minutes: 59)), l10n.homeTimeMinutesAgo(59));
        expect(ago(const Duration(hours: 1)), l10n.homeTimeHoursAgo(1));
        expect(ago(const Duration(days: 3)), l10n.homeTimeHoursAgo(72));
        final old = now.subtract(const Duration(days: 3, seconds: 1));
        expect(formatUpdateTime(old, l10n, now: now), formatLocalDate(old));
        final future = now.add(const Duration(minutes: 1));
        expect(
          formatUpdateTime(future, l10n, now: now),
          formatLocalDate(future),
        );
      }
    },
  );

  testWidgets(
    'home update and notice publication use the same local timezone',
    (tester) async {
      final utc = DateTime(2026, 7, 7, 0, 5).toUtc();
      await tester.pumpWidget(
        app(
          EleconHomePage(
            loadSnapshot: () async => CampusSnapshot(
              schoolName: '测试大学',
              updatedAt: utc,
              notices: NoticeList(
                items: [
                  NoticeListItems(
                    id: 'synthetic-notice',
                    title: '合成通知',
                    category: 'admin',
                    source: '测试部门',
                    publishedAt: utc.toIso8601String(),
                    content: '合成正文',
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('测试大学'), findsOneWidget);
      expect(find.text('更新于 2026-07-07'), findsOneWidget);
      expect(find.text('elecon'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('home-card:notice')));
      await tester.pumpAndSettle();
      expect(find.text('测试部门 · 行政 · 2026-07-07'), findsOneWidget);
      await tester.tap(find.text('合成通知'));
      await tester.pumpAndSettle();
      expect(find.text('测试部门 · 2026-07-07'), findsOneWidget);
      expect(find.text('合成正文'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final publishedAt in [null, 'invalid-date']) {
    testWidgets(
      'missing or invalid publication date has no placeholder: $publishedAt',
      (tester) async {
        await tester.pumpWidget(
          app(
            Scaffold(
              body: NoticeCard(
                NoticeList(
                  items: [
                    NoticeListItems(
                      id: 'synthetic-notice',
                      title: '合成通知',
                      category: 'admin',
                      source: '测试部门',
                      publishedAt: publishedAt,
                      summary: '   ',
                      author: '   ',
                      department: '',
                      content: '合成正文',
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('测试部门 · 行政'), findsOneWidget);
        expect(find.textContaining('invalid-date'), findsNothing);
        await tester.tap(find.text('合成通知'));
        await tester.pumpAndSettle();
        expect(find.text('测试部门'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('notice heading and metadata follow the selected language', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        const Scaffold(
          body: NoticeCard(
            NoticeList(
              items: [
                NoticeListItems(
                  id: 'synthetic-notice',
                  title: 'Synthetic notice',
                  category: 'admin',
                  source: 'Synthetic source',
                ),
              ],
            ),
          ),
        ),
        language: 'en',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Notices'), findsOneWidget);
    expect(find.text('1 recent notice'), findsOneWidget);
    expect(find.text('Synthetic source · Administration'), findsOneWidget);
  });

  for (final (width, scale, stacked) in [
    (1000.0, 1.0, false),
    (240.0, 1.0, true),
    (320.0, 2.0, true),
  ]) {
    testWidgets('generic fields adapt to width $width and text scale $scale', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const label = '合成字段名称';
      const value = '这是一段较长的合成字段值，用于验证窄屏与大字体时能够完整展示。';
      await tester.pumpWidget(
        app(
          const Scaffold(
            body: SingleChildScrollView(
              child: GenericSectionCard(
                GenericSection(
                  sectionId: 'synthetic.section',
                  title: '合成通用信息',
                  fields: [
                    GenericField(
                      label: label,
                      role: GenericRole.label,
                      value: value,
                    ),
                  ],
                ),
              ),
            ),
          ),
          textScale: scale,
        ),
      );
      await tester.pumpAndSettle();

      final labelRect = tester.getRect(find.text(label));
      final valueRect = tester.getRect(find.text(value));
      if (stacked) {
        expect(valueRect.top, greaterThan(labelRect.bottom));
      } else {
        expect(valueRect.top, labelRect.top);
        expect(valueRect.left, greaterThan(labelRect.right));
      }
      expect(valueRect.right, lessThanOrEqualTo(width));
      expect(tester.takeException(), isNull);
    });
  }
}
