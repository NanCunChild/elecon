/// 首页演示数据（demo / 占位）。
///
/// 仅用于在真实 adapter 数据闭环前驱动 UI 预览；**不是**任何真实学校数据。
/// 真实数据接入后，`EleconHomePage` 应改由核心/adapter 产出的 snapshot 驱动。
/// 契约对象一律用 `elecon_contract` 生成类型构造（经 models.dart re-export），
/// 与 schema 同形（审阅 P0-1）。
library;

import 'models.dart';

Future<CampusSnapshot> loadDemoCampusSnapshot() async {
  await Future<void>.delayed(const Duration(milliseconds: 350));
  return CampusSnapshot(
    schoolName: '示例大学',
    updatedAt: DateTime.utc(2026, 7, 6, 8, 30),
    schedule: const ScheduleWeek(
      term: '2025-2026-2',
      week: 18,
      days: [
        ScheduleWeekDays(
          dayOfWeek: 1,
          slots: [
            ScheduleWeekDaysSlots(
              start: '08:30',
              end: '10:05',
              courseName: '数据结构',
              teacher: '李老师',
              location: 'A-301',
            ),
            ScheduleWeekDaysSlots(
              start: '14:00',
              end: '15:35',
              courseName: '大学英语',
              location: 'B-104',
            ),
          ],
        ),
        ScheduleWeekDays(
          dayOfWeek: 3,
          slots: [
            ScheduleWeekDaysSlots(
              start: '10:25',
              end: '12:00',
              courseName: '计算机网络',
              teacher: '王老师',
              location: '实验楼 2-206',
            ),
          ],
        ),
      ],
    ),
    grades: const GradesList(
      term: '2025-2026-1',
      items: [
        GradesListItems(
          courseId: 'DEMO-MATH-101',
          courseName: '高等数学',
          credit: 5,
          score: GradesListItemsScore(kind: 'numeric', value: 91, max: 100),
          category: 'required',
          status: 'final',
          gradePoint: 4.1,
        ),
        GradesListItems(
          courseId: 'DEMO-CS-100',
          courseName: '程序设计基础',
          credit: 4,
          score: GradesListItemsScore(kind: 'letter', value: 'A'),
          category: 'required',
          status: 'final',
          gradePoint: 4.3,
        ),
        GradesListItems(
          courseId: 'DEMO-GEN-001',
          courseName: '创新创业导论',
          credit: 1,
          score: GradesListItemsScore(kind: 'passfail', value: '通过'),
          category: 'elective',
          status: 'final',
        ),
      ],
    ),
    notices: const NoticeList(
      items: [
        NoticeListItems(
          id: 'demo-notice-1',
          title: '期末考试周教学安排提醒',
          category: 'academic',
          source: '教务处',
          summary: '请同学们按准考证时间地点参加考试。',
          publishedAt: '2026-07-03T00:00:00Z',
        ),
        NoticeListItems(
          id: 'demo-notice-2',
          title: '暑期校园服务时间调整',
          category: 'admin',
          source: '学校办公室',
          publishedAt: '2026-07-01T00:00:00Z',
        ),
      ],
    ),
    genericSections: const [
      GenericSection(
        sectionId: 'dorm.energy',
        title: '宿舍水电',
        fields: [
          GenericField(
              label: '房间', role: GenericRole.identifier, value: '12-345'),
          GenericField(label: '电费余额', role: GenericRole.amount, value: 3280),
          GenericField(label: '状态', role: GenericRole.status, value: '正常'),
        ],
      ),
      GenericSection(
        sectionId: 'library.seats',
        title: '图书馆座位',
        table: GenericTable(
          columns: [
            GenericColumn(label: '区域', role: GenericRole.label),
            GenericColumn(label: '剩余', role: GenericRole.quantity),
            GenericColumn(label: '状态', role: GenericRole.status),
          ],
          rows: [
            ['三层东区', 28, '充足'],
            ['五层自习区', 6, '紧张'],
          ],
        ),
      ),
    ],
  );
}
