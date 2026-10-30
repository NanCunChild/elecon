import 'dart:async';
import 'dart:convert';

import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/home/home_page.dart';
import 'package:elecon_contract/notice_detail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/school_fixture.dart';

const item = NoticeListItems(
  id: '42',
  title: '合成公告',
  category: 'academic',
  source: '合成来源',
);

Widget app(
  NoticeDetailLoader? load, {
  SessionController? session,
  NoticeListItems notice = item,
}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('zh'),
  home: session == null
      ? NoticeDetailPage(item: notice, loadDetail: load)
      : SessionScope(
          controller: session,
          child: NoticeDetailPage(item: notice, loadDetail: load),
        ),
);

ScriptPackage package(String version) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 4,
      'id': 'school.synthetic',
      'version': version,
      'schoolId': 'synthetic',
      'name': 'Synthetic school',
      'network': {'origins': []},
      'browser': false,
      'capabilities': [
        {
          'id': 'notice.list',
          'schema': 'elecon.notice.list',
          'schemaVersion': '1.1',
        },
      ],
    },
    'source':
        'export const capabilities={"notice.list":async()=>({items:[]})};',
  }),
);

void expectInvalidated(WidgetTester tester) {
  expect(find.text('正文暂时无法获取，请重试。'), findsOneWidget);
  expect(
    tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
    isNull,
  );
  for (final text in ['合成公告', '合成来源', '原详情标题', '原详情正文', '原附件.pdf', '原快照正文']) {
    expect(find.text(text), findsNothing);
  }
}

void main() {
  testWidgets(
    'detail shows loading then selectable plain text and attachment names',
    (tester) async {
      final complete = Completer<NoticeDetail?>();
      await tester.pumpWidget(app(() => complete.future));
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      complete.complete(
        const NoticeDetail(
          id: '42',
          title: '合成完整标题',
          content: '第一段\n\n第二段',
          attachments: [
            NoticeDetailAttachments(
              name: '合成附件.pdf',
              url: 'https://example.invalid/file.pdf',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('合成完整标题'), findsOneWidget);
      expect(find.text('第一段\n\n第二段'), findsOneWidget);
      expect(find.byType(SelectableText), findsOneWidget);
      expect(find.text('合成附件.pdf'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    },
  );

  testWidgets('failed detail can be retried without echoing raw exceptions', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      app(() async {
        if (++calls == 1) {
          throw StateError(
            'SYNTHETIC_SECRET https://example.invalid/?token=private',
          );
        }
        return const NoticeDetail(id: '42', title: '合成公告', content: '重试正文');
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('正文暂时无法获取，请重试。'), findsOneWidget);
    expect(find.textContaining('SYNTHETIC_SECRET'), findsNothing);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('重试正文'), findsOneWidget);
    expect(calls, 2);
  });

  testWidgets(
    'missing text is an empty state and wrong notice ids are rejected',
    (tester) async {
      await tester.pumpWidget(
        app(() async => const NoticeDetail(id: '42', title: '合成公告')),
      );
      await tester.pumpAndSettle();
      expect(find.text('本条通知未提供文字正文。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        app(
          () async =>
              const NoticeDetail(id: '99', title: '错误公告', content: '不得显示'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('不得显示'), findsNothing);
      expect(find.text('正文暂时无法获取，请重试。'), findsOneWidget);
    },
  );

  testWidgets('late result after disposal cannot update the page', (
    tester,
  ) async {
    final complete = Completer<NoticeDetail?>();
    await tester.pumpWidget(app(() => complete.future));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    complete.complete(
      const NoticeDetail(id: '42', title: '晚到公告', content: '晚到正文'),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('晚到正文'), findsNothing);
  });

  for (final action in ['logout', 'update']) {
    testWidgets('completed detail is hidden after same-school $action', (
      tester,
    ) async {
      final school = testSchool(schoolId: 'synthetic');
      final session = SessionController(initialSchools: [school]);
      addTearDown(session.dispose);
      session.selectSchool(school);
      if (action == 'update') {
        final first = package('1.0.0');
        await session.installTrustedScript(first, approvedDigest: first.digest);
      }
      var calls = 0;
      await tester.pumpWidget(
        app(() async {
          calls++;
          return const NoticeDetail(
            id: '42',
            title: '原详情标题',
            content: '原详情正文',
            attachments: [
              NoticeDetailAttachments(
                name: '原附件.pdf',
                url: 'https://example.invalid/file.pdf',
              ),
            ],
          );
        }, session: session),
      );
      await tester.pumpAndSettle();
      expect(find.text('原详情正文'), findsOneWidget);
      if (action == 'logout') {
        session.logout();
      } else {
        final next = package('1.0.1');
        await session.installTrustedScript(next, approvedDigest: next.digest);
      }
      await tester.pumpAndSettle();
      expectInvalidated(tester);
      expect(calls, 1);
    });
  }

  testWidgets(
    'school switch hides snapshot content and attachments without querying the new identity',
    (tester) async {
      final first = testSchool(schoolId: 'synthetic');
      final second = testSchool(schoolId: 'other');
      final session = SessionController(initialSchools: [first, second]);
      addTearDown(session.dispose);
      session.selectSchool(first);
      var calls = 0;
      await tester.pumpWidget(
        app(
          () async {
            calls++;
            return null;
          },
          session: session,
          notice: const NoticeListItems(
            id: '42',
            title: '合成公告',
            category: 'academic',
            source: '合成来源',
            content: '原快照正文',
            attachments: [
              NoticeListItemsAttachments(
                name: '原附件.pdf',
                url: 'https://example.invalid/file.pdf',
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('原快照正文'), findsOneWidget);
      session.selectSchool(second);
      await tester.pumpAndSettle();
      expectInvalidated(tester);
      expect(calls, 0);
    },
  );

  testWidgets('same-school controller replacement invalidates an open detail', (
    tester,
  ) async {
    final school = testSchool(schoolId: 'synthetic');
    final first = SessionController(initialSchools: [school]);
    final second = SessionController(initialSchools: [school]);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    first.selectSchool(school);
    second.selectSchool(school);
    var calls = 0;
    Future<NoticeDetail?> load() async {
      calls++;
      return const NoticeDetail(id: '42', title: '原详情标题', content: '原详情正文');
    }

    await tester.pumpWidget(app(load, session: first));
    await tester.pumpAndSettle();
    await tester.pumpWidget(app(load, session: second));
    await tester.pumpAndSettle();
    expectInvalidated(tester);
    expect(calls, 1);
  });

  testWidgets('late detail after logout cannot restore old identity content', (
    tester,
  ) async {
    final school = testSchool(schoolId: 'synthetic');
    final session = SessionController(initialSchools: [school]);
    addTearDown(session.dispose);
    session.selectSchool(school);
    final complete = Completer<NoticeDetail?>();
    await tester.pumpWidget(app(() => complete.future, session: session));
    await tester.pump();
    session.logout();
    await tester.pumpAndSettle();
    complete.complete(
      const NoticeDetail(id: '42', title: '原详情标题', content: '原详情正文'),
    );
    await tester.pumpAndSettle();
    expectInvalidated(tester);
    expect(tester.takeException(), isNull);
  });
}
