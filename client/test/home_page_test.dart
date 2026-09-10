import 'dart:async';

import 'package:elecon/ui/home/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('home page renders demo campus cards', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: EleconHomePage(
          loadSnapshot: () async => CampusSnapshot(
            schoolName: '测试大学',
            updatedAt: DateTime.utc(2026, 7, 6, 8, 30),
            grades: const GradesList(
              term: '2025-2026-1',
              gradePointScale: '4.0',
              items: [
                GradesListItems(
                  courseId: 'TEST-101',
                  courseName: '测试课程',
                  credit: 2,
                  score: GradesListItemsScore(kind: 'numeric', value: 95),
                  category: 'required',
                  status: 'final',
                  gradePoint: 4.0,
                ),
              ],
            ),
            notices: const NoticeList(
              items: [
                NoticeListItems(
                  id: 'test-1',
                  title: '测试通知',
                  category: 'admin',
                  source: '测试部门',
                ),
              ],
            ),
            genericSections: const [
              GenericSection(
                sectionId: 'generic.test',
                title: '通用信息',
                fields: [
                  GenericField(
                    label: '状态',
                    role: GenericRole.status,
                    value: '正常',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('elecon'), findsWidgets);
    expect(find.textContaining('测试大学'), findsOneWidget);
    expect(find.text('成绩'), findsOneWidget);
    expect(find.text('测试课程'), findsOneWidget);
    expect(find.text('通知'), findsOneWidget);
    expect(find.text('测试通知'), findsOneWidget);
    expect(find.text('通用信息'), findsOneWidget);
  });

  testWidgets('tapping a grades row drills into course detail (ADR-025)', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: EleconHomePage(
          loadSnapshot: () async => CampusSnapshot(
            schoolName: '测试大学',
            updatedAt: DateTime.utc(2026, 7, 6, 8, 30),
            grades: const GradesList(
              term: '2025-2026-1',
              gradePointScale: '4.0',
              items: [
                GradesListItems(
                  courseId: 'TEST-101',
                  courseName: '测试课程',
                  credit: 2,
                  score: GradesListItemsScore(kind: 'numeric', value: 95),
                  category: 'required',
                  status: 'final',
                  teacher: '张老师',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('测试课程'));
    await tester.pumpAndSettle();

    // 详情页专有内容：课程号与任课教师（App 内下钻，无网络、无外链）。
    expect(find.text('课程号'), findsOneWidget);
    expect(find.text('TEST-101'), findsOneWidget);
    expect(find.text('张老师'), findsOneWidget);
  });

  testWidgets('tapping a notice row drills into notice detail (ADR-025)', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: EleconHomePage(
          loadSnapshot: () async => CampusSnapshot(
            schoolName: '测试大学',
            updatedAt: DateTime.utc(2026, 7, 6, 8, 30),
            notices: const NoticeList(
              items: [
                NoticeListItems(
                  id: 'test-1',
                  title: '测试通知',
                  category: 'admin',
                  source: '测试部门',
                  content: '这是通知正文',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('测试通知'));
    await tester.pumpAndSettle();

    expect(find.text('通知详情'), findsOneWidget);
    expect(find.text('这是通知正文'), findsOneWidget);
  });

  testWidgets('home page renders error state', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: EleconHomePage(
          loadSnapshot: () async => throw StateError('boom'),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('加载失败'), findsOneWidget);
    expect(find.textContaining('boom'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets(
    'refresh waits for the latest generation and ignores stale data',
    (tester) async {
      final firstRefresh = Completer<CampusSnapshot>();
      final secondRefresh = Completer<CampusSnapshot>();
      var calls = 0;
      Future<CampusSnapshot> load() {
        calls += 1;
        if (calls == 1) {
          return Future.value(_snapshot('初始大学'));
        }
        if (calls == 2) return firstRefresh.future;
        return secondRefresh.future;
      }

      await tester.pumpWidget(
        MaterialApp(home: EleconHomePage(loadSnapshot: load)),
      );
      await tester.pumpAndSettle();

      final refresh = tester.widget<RefreshIndicator>(
        find.byType(RefreshIndicator),
      );
      var refreshDone = false;
      final refreshFuture = refresh.onRefresh().whenComplete(
        () => refreshDone = true,
      );
      await tester.pump();
      expect(refreshDone, isFalse);
      expect(find.textContaining('初始大学'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pump();
      firstRefresh.complete(_snapshot('过期大学'));
      await tester.pump();
      expect(refreshDone, isFalse);
      expect(find.textContaining('过期大学'), findsNothing);

      secondRefresh.complete(_snapshot('最新大学'));
      await refreshFuture;
      await tester.pumpAndSettle();
      expect(refreshDone, isTrue);
      expect(find.textContaining('最新大学'), findsOneWidget);
    },
  );

  testWidgets('GPA excludes non-positive credits and never renders NaN', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: EleconHomePage(
          loadSnapshot: () async => CampusSnapshot(
            schoolName: '测试大学',
            updatedAt: DateTime.utc(2026, 8, 6),
            grades: const GradesList(
              term: '2025-2026-2',
              gradePointScale: '4.0',
              items: [
                GradesListItems(
                  courseId: 'ZERO',
                  courseName: '零学分课程',
                  credit: 0,
                  score: GradesListItemsScore(kind: 'numeric', value: 90),
                  category: 'elective',
                  status: 'final',
                  gradePoint: 4,
                ),
                GradesListItems(
                  courseId: 'NEG',
                  courseName: '负学分课程',
                  credit: -1,
                  score: GradesListItemsScore(kind: 'numeric', value: 80),
                  category: 'elective',
                  status: 'final',
                  gradePoint: 3,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('GPA'), findsNothing);
    expect(find.textContaining('NaN'), findsNothing);
    expect(find.textContaining('Infinity'), findsNothing);
    expect(find.text('零学分课程'), findsOneWidget);
    expect(find.text('负学分课程'), findsOneWidget);
  });

  // ADR-001 §3.5：课程级 gradePoint 的换算尺度是校本的，本体只在知道满分档时
  // 才敢聚合。以下三例锁住这道门。
  testWidgets('GPA is withheld when gradePointScale is absent', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: EleconHomePage(
          loadSnapshot: () async => CampusSnapshot(
            schoolName: '测试大学',
            updatedAt: DateTime.utc(2026, 9, 8),
            grades: const GradesList(
              term: '2025-2026-2',
              items: [
                GradesListItems(
                  courseId: 'NOSCALE',
                  courseName: '无尺度课程',
                  credit: 3,
                  score: GradesListItemsScore(kind: 'numeric', value: 90),
                  category: 'required',
                  status: 'final',
                  gradePoint: 4,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('GPA'), findsNothing);
    expect(find.text('无尺度课程'), findsOneWidget);
  });

  testWidgets('GPA is withheld when gradePointScale is not aggregatable', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: EleconHomePage(
          loadSnapshot: () async => CampusSnapshot(
            schoolName: '测试大学',
            updatedAt: DateTime.utc(2026, 9, 8),
            grades: const GradesList(
              term: '2025-2026-2',
              gradePointScale: 'other',
              items: [
                GradesListItems(
                  courseId: 'OTHER',
                  courseName: '异制课程',
                  credit: 3,
                  score: GradesListItemsScore(kind: 'numeric', value: 90),
                  category: 'required',
                  status: 'final',
                  gradePoint: 4,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('GPA'), findsNothing);
    expect(find.text('异制课程'), findsOneWidget);
  });

  testWidgets('local aggregate renders with its scale and a distinct label', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: EleconHomePage(
          loadSnapshot: () async => CampusSnapshot(
            schoolName: '测试大学',
            updatedAt: DateTime.utc(2026, 9, 8),
            grades: const GradesList(
              term: '2025-2026-2',
              gradePointScale: '4.3',
              items: [
                GradesListItems(
                  courseId: 'SCALED',
                  courseName: '有尺度课程',
                  credit: 2,
                  score: GradesListItemsScore(kind: 'numeric', value: 95),
                  category: 'required',
                  status: 'final',
                  gradePoint: 4.3,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 本机聚合**不叫 GPA**——官方数与自算值同名是 ADR-001 §3.5 优先级规则第 3 条
    // 明令禁止的形态。
    expect(
      find.textContaining('均绩 4.30（4.3 制 · 本机计算）'),
      findsOneWidget,
    );
    expect(find.textContaining('GPA'), findsNothing);
  });

  // ADR-001 §3.5 优先级规则：gpa.summary 存在即权威，本体不得用自算值覆盖。
  testWidgets('official gpa.summary wins over the local aggregate', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: EleconHomePage(
          loadSnapshot: () async => CampusSnapshot(
            schoolName: '测试大学',
            updatedAt: DateTime.utc(2026, 9, 9),
            // 学校官方数 3.71，与本机按 4.3 聚合出的 4.30 **刻意不同**——
            // 断言展示的是官方数，才证明没有被自算值覆盖。
            gpaSummary: const GpaSummary(gpa: 3.71, gradePointScale: '4.3'),
            grades: const GradesList(
              term: '2025-2026-2',
              gradePointScale: '4.3',
              items: [
                GradesListItems(
                  courseId: 'SCALED',
                  courseName: '有尺度课程',
                  credit: 2,
                  score: GradesListItemsScore(kind: 'numeric', value: 95),
                  category: 'required',
                  status: 'final',
                  gradePoint: 4.3,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('GPA 3.71（4.3 制）'), findsOneWidget);
    expect(find.textContaining('4.30'), findsNothing);
    expect(find.textContaining('本机计算'), findsNothing);
  });

  testWidgets('official gpa without an aggregatable scale falls back to local', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: EleconHomePage(
          loadSnapshot: () async => CampusSnapshot(
            schoolName: '测试大学',
            updatedAt: DateTime.utc(2026, 9, 9),
            // 官方数存在但尺度不可判读 → 不得当绩点展示（fail-closed），
            // 退回本机聚合（它有自己的、可判读的尺度）。
            gpaSummary: const GpaSummary(gpa: 3.71, gradePointScale: 'other'),
            grades: const GradesList(
              term: '2025-2026-2',
              gradePointScale: '4.3',
              items: [
                GradesListItems(
                  courseId: 'SCALED',
                  courseName: '有尺度课程',
                  credit: 2,
                  score: GradesListItemsScore(kind: 'numeric', value: 95),
                  category: 'required',
                  status: 'final',
                  gradePoint: 4.3,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('3.71'), findsNothing);
    expect(
      find.textContaining('均绩 4.30（4.3 制 · 本机计算）'),
      findsOneWidget,
    );
  });
}

CampusSnapshot _snapshot(String schoolName) => CampusSnapshot(
  schoolName: schoolName,
  updatedAt: DateTime.utc(2026, 8, 6),
  notices: const NoticeList(
    items: [
      NoticeListItems(
        id: 'notice',
        title: '测试通知',
        category: 'admin',
        source: '测试部门',
      ),
    ],
  ),
);
