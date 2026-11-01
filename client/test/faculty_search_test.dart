import 'dart:async';
import 'dart:convert';

import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/session/session_scope.dart';
import 'package:elecon/ui/home/faculty_search_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/school_fixture.dart';

FacultySearch result(int page, {bool empty = false}) => FacultySearch(
  items: empty
      ? const []
      : [
          FacultySearchItems(
            id: '$page',
            name: '合成教师$page',
            department: '合成学院',
            title: '教授',
            summary: '合成简介$page',
            profileUrl: 'https://example.invalid/faculty/$page',
          ),
        ],
  page: page,
  pageSize: 10,
  hasMore: !empty && page == 1,
  total: empty ? 0 : 11,
  sourceSystem: 'synthetic-faculty',
  sourceUrl: 'https://example.invalid/',
);

Widget app(FacultySearchLoader loader, {SessionController? session}) {
  final body = SingleChildScrollView(
    child: FacultySearchSection(loadSearch: loader),
  );
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: Scaffold(
      body: session == null
          ? body
          : SessionScope(controller: session, child: body),
    ),
  );
}

Future<void> search(WidgetTester tester, [String text = '合成']) async {
  await tester.enterText(find.byKey(const Key('faculty-name')), text);
  await tester.pump();
  await tester.tap(find.byKey(const Key('faculty-search')));
  await tester.pumpAndSettle();
}

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
          'id': 'faculty.search',
          'schema': 'elecon.faculty.search',
          'schemaVersion': '1.0',
        },
      ],
    },
    'source': 'export const capabilities={"faculty.search":async()=>({})};',
  }),
);

void main() {
  test('whole-page decoding preserves source and rejects malformed rows', () {
    final raw = <String, Object?>{
      'items': [
        {'id': 'one', 'name': '合成教师', 'summary': '简介'},
      ],
      'page': 1,
      'pageSize': 10,
      'hasMore': false,
      'total': 1,
      'sourceSystem': 'synthetic',
      'sourceUrl': 'https://example.invalid/',
    };
    final decoded = facultySearchFromDynamic(raw)!;
    expect(decoded.items.single.id, 'one');
    expect(decoded.sourceSystem, 'synthetic');
    expect(decoded.total, 1);
    expect(
      facultySearchFromDynamic({
        ...raw,
        'sourceUrl': 'http://example.invalid/',
      }),
      isNull,
    );
    expect(
      facultySearchFromDynamic({
        ...raw,
        'items': [
          {'id': 'one'},
        ],
      }),
      isNull,
    );
    expect(
      facultySearchFromDynamic({
        ...raw,
        'items': [
          {'id': 'one', 'name': 'A'},
          {'id': 'one', 'name': 'B'},
        ],
        'total': 2,
      }),
      isNull,
    );
  });

  testWidgets(
    'manual search paginates submitted filters and shows same-page details',
    (tester) async {
      final calls = <Map<String, dynamic>>[];
      await tester.pumpWidget(
        app((params) async {
          calls.add(Map.of(params));
          return result(params['page'] as int);
        }),
      );
      expect(calls, isEmpty);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('faculty-search')))
            .onPressed,
        isNull,
      );
      await search(tester);
      expect(find.text('合成教师1'), findsOneWidget);
      expect(find.text('来源：example.invalid'), findsOneWidget);
      await tester.tap(find.text('合成教师1'));
      await tester.pumpAndSettle();
      expect(find.text('合成简介1'), findsOneWidget);
      expect(find.text('https://example.invalid/faculty/1'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('faculty-name')), '未提交的新条件');
      await tester.ensureVisible(find.byKey(const Key('faculty-next')));
      await tester.tap(find.byKey(const Key('faculty-next')));
      await tester.pumpAndSettle();
      expect(calls.last, {'query': '合成', 'page': 2, 'pageSize': 10});
      expect(find.text('合成教师2'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('faculty-search')));
      await tester.tap(find.byKey(const Key('faculty-search')));
      await tester.pumpAndSettle();
      expect(calls.last, {'query': '未提交的新条件', 'page': 1, 'pageSize': 10});
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'public profile has an explicit copy action and completion feedback',
    (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(app((_) async => result(1)));
      await search(tester);
      await tester.tap(find.text('合成教师1'));
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(
        tester.element(find.byType(FacultySearchSection)),
      );
      await tester.ensureVisible(find.text(l10n.commonCopyLink));
      await tester.tap(find.text(l10n.commonCopyLink));
      await tester.pumpAndSettle();
      expect(copied, 'https://example.invalid/faculty/1');
      expect(find.text(l10n.commonLinkCopied), findsOneWidget);
    },
  );

  testWidgets(
    'errors remain failures, retry is explicit, empty results are distinct',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        app((params) async {
          if (++calls == 1) throw StateError('SYNTHETIC_SECRET');
          return result(1, empty: true);
        }),
      );
      await search(tester);
      expect(find.text('教师信息暂时无法获取，请重试。'), findsOneWidget);
      expect(find.textContaining('SYNTHETIC_SECRET'), findsNothing);
      expect(find.text('没有找到匹配的教师。'), findsNothing);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('没有找到匹配的教师。'), findsOneWidget);
      expect(find.text('共 0 条结果'), findsOneWidget);
      expect(calls, 2);
    },
  );

  for (final action in ['logout', 'update', 'switch']) {
    testWidgets(
      'completed results are removed on $action without querying a new identity',
      (tester) async {
        final school = testSchool(schoolId: 'synthetic');
        final other = testSchool(schoolId: 'other');
        final session = SessionController(initialSchools: [school, other]);
        addTearDown(session.dispose);
        session.selectSchool(school);
        if (action == 'update') {
          final first = package('1.0.0');
          await session.installTrustedScript(
            first,
            approvedDigest: first.digest,
          );
        }
        var calls = 0;
        await tester.pumpWidget(
          app((params) async {
            calls++;
            return result(1);
          }, session: session),
        );
        await search(tester);
        expect(find.text('合成教师1'), findsOneWidget);
        if (action == 'logout') {
          session.logout();
        } else if (action == 'switch') {
          session.selectSchool(other);
        } else {
          final updated = package('1.0.1');
          await session.installTrustedScript(
            updated,
            approvedDigest: updated.digest,
          );
        }
        await tester.pumpAndSettle();
        expect(find.text('合成教师1'), findsNothing);
        expect(
          find.text(
            AppLocalizations.of(
              tester.element(find.byType(FacultySearchSection)),
            ).homeCardDataChanged,
          ),
          findsOneWidget,
        );
        expect(calls, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('late result after source generation change is ignored', (
    tester,
  ) async {
    final school = testSchool(schoolId: 'synthetic');
    final session = SessionController(initialSchools: [school]);
    addTearDown(session.dispose);
    session.selectSchool(school);
    final complete = Completer<FacultySearch?>();
    await tester.pumpWidget(app((_) => complete.future, session: session));
    await tester.enterText(find.byKey(const Key('faculty-name')), '合成');
    await tester.pump();
    await tester.tap(find.byKey(const Key('faculty-search')));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    session.logout();
    await tester.pump();
    complete.complete(result(1));
    await tester.pumpAndSettle();
    expect(find.text('合成教师1'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow screen and large text keep pagination within the page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(app((_) async => result(1)));
    await search(tester);
    expect(tester.takeException(), isNull);
  });
}
