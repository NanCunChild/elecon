/// M4 取数解码器单测：adapter 产出（JSON 往返 Map）→ 契约 view 类型。
///
/// 覆盖 grades.list / schedule.week / classroom.buildings / classroom.available，
/// 校验必填缺失丢弃、可选缺失置 null、类型宽容（红线 #6：不臆造字段）。
/// 输入为脱敏内联样例，形状对齐 school-xidian adapter 产出与 contract/schema。
library;

import 'package:elecon/ui/home/schema_decode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('gradesListFromDynamic', () {
    test('解出学期与合法条目；score.value 原样透传', () {
      final out = gradesListFromDynamic({
        'term': '2025-2026-1',
        'items': [
          {
            'courseId': 'CS101',
            'courseName': '计算机导论',
            'credit': 3,
            'category': 'required',
            'status': 'passed',
            'score': {'kind': 'numeric', 'value': 92},
            'gradePoint': 4.0,
          },
        ],
      });
      expect(out, isNotNull);
      expect(out!.term, '2025-2026-1');
      expect(out.items, hasLength(1));
      expect(out.items.first.courseName, '计算机导论');
      expect(out.items.first.score.value, 92);
      expect(out.items.first.score.kind, 'numeric');
    });

    test('通过制 value 为字符串亦透传', () {
      final out = gradesListFromDynamic({
        'term': 't',
        'items': [
          {
            'courseId': 'X',
            'courseName': '体育',
            'credit': 1,
            'category': 'required',
            'status': 'passed',
            'score': {'kind': 'pass_fail', 'value': '通过'},
          },
        ],
      });
      expect(out!.items.first.score.value, '通过');
    });

    test('缺 term 或缺 score → 丢弃', () {
      expect(gradesListFromDynamic({'items': []}), isNull);
      final out = gradesListFromDynamic({
        'term': 't',
        'items': [
          {
            'courseId': 'X',
            'courseName': 'Y',
            'credit': 1,
            'category': 'required',
            'status': 'passed',
            // 无 score
          },
        ],
      });
      expect(out!.items, isEmpty);
    });
  });

  group('scheduleWeekFromDynamic', () {
    test('解出周次与节次标签（start/end 为字符串）', () {
      final out = scheduleWeekFromDynamic({
        'term': '2025-2026-1',
        'week': 3,
        'days': [
          {
            'dayOfWeek': 1,
            'slots': [
              {
                'start': '1',
                'end': '2',
                'courseName': '高等数学',
                'location': 'A-101',
                'teacher': '张老师',
              },
            ],
          },
        ],
      });
      expect(out, isNotNull);
      expect(out!.week, 3);
      expect(out.days.first.slots.first.start, '1');
      expect(out.days.first.slots.first.courseName, '高等数学');
      expect(out.days.first.slots.first.location, 'A-101');
    });

    test('缺 week → 丢弃；缺 courseName 的 slot 被过滤', () {
      expect(scheduleWeekFromDynamic({'term': 't', 'days': []}), isNull);
      final out = scheduleWeekFromDynamic({
        'term': 't',
        'week': 1,
        'days': [
          {
            'dayOfWeek': 2,
            'slots': [
              {'start': '1', 'end': '2'},
            ],
          },
        ],
      });
      expect(out!.days.first.slots, isEmpty);
    });
  });

  group('classroomBuildingsFromDynamic', () {
    test('解出教学楼列表（含 roomCount）', () {
      final out = classroomBuildingsFromDynamic({
        'items': [
          {'building': 'A 楼', 'buildingId': 'A', 'roomCount': 40},
          {'building': 'B 楼'},
        ],
      });
      expect(out!.items, hasLength(2));
      expect(out.items!.first.buildingId, 'A');
      expect(out.items!.first.roomCount, 40);
      expect(out.items![1].roomCount, isNull);
    });

    test('空串 building 被过滤', () {
      final out = classroomBuildingsFromDynamic({
        'items': [
          {'building': ''},
        ],
      });
      expect(out!.items, isEmpty);
    });
  });

  group('classroomAvailableFromDynamic', () {
    test('解出教室与分节占用', () {
      final out = classroomAvailableFromDynamic({
        'date': '2026-07-25',
        'items': [
          {
            'building': 'A 楼',
            'room': 'A-101',
            'capacity': 60,
            'occupied': false,
            'status': 'available',
            'sections': [
              {'index': 1, 'occupied': false, 'label': '第1节'},
              {'index': 2, 'occupied': true},
            ],
          },
        ],
      });
      expect(out!.date, '2026-07-25');
      expect(out.items, hasLength(1));
      final room = out.items!.first;
      expect(room.room, 'A-101');
      expect(room.occupied, false);
      expect(room.sections, hasLength(2));
      expect(room.sections!.first.label, '第1节');
    });

    test('缺 building/room 的条目被丢弃', () {
      final out = classroomAvailableFromDynamic({
        'items': [
          {'room': 'A-101'},
          {'building': 'A 楼'},
        ],
      });
      expect(out!.items, isEmpty);
    });
  });
}
