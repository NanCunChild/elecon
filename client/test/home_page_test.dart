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
                      label: '状态', role: GenericRole.status, value: '正常'),
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
}
