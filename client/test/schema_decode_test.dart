/// M4 取数解码器单测：adapter 产出（JSON 往返 Map）→ 契约 view 类型。
///
/// 覆盖 grades.list / schedule.week / classroom.* / exam.list / library.loans，
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
        'gradePointScale': '4.3',
        'items': [
          {
            'courseId': 'CS101',
            'courseName': '计算机导论',
            'credit': 3,
            'category': 'required',
            'status': 'passed',
            'score': {'kind': 'numeric', 'value': 92},
            'gradePoint': 4.0,
            'gradePointSource': 'adapter-derived',
          },
        ],
      });
      expect(out, isNotNull);
      expect(out!.term, '2025-2026-1');
      expect(out.gradePointScale, '4.3');
      expect(out.items, hasLength(1));
      expect(out.items.first.courseName, '计算机导论');
      expect(out.items.first.score.value, 92);
      expect(out.items.first.score.kind, 'numeric');
      expect(out.items.first.gradePointSource, 'adapter-derived');
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

  group('card schema decode', () {
    test('余额保持整数最小货币单位并解出脱敏卡号', () {
      final out = cardBalanceFromDynamic({
        'cardNumber': '00000042',
        'cardNumberMasked': '****0042',
        'balance': {'amountMinor': 1234, 'currency': 'CNY'},
        'status': 'active',
      });
      expect(out, isNotNull);
      expect(out!.balance.amountMinor, 1234);
      expect(out.cardNumberMasked, '****0042');
      expect(cardBalanceFromDynamic({'cardNumber': 'x'}), isNull);
    });

    test('余额拒绝非整数最小货币单位而非静默截断', () {
      final out = cardBalanceFromDynamic({
        'cardNumber': '00000042',
        'balance': {'amountMinor': 1234.9, 'currency': 'CNY'},
      });
      expect(out, isNull);
    });

    test('交易列表过滤缺失必填字段的条目', () {
      final out = cardTransactionsFromDynamic({
        'cardNumber': '00000042',
        'page': 1,
        'items': [
          {
            'time': '2026-07-26T08:00:00Z',
            'amountMinor': 850,
            'currency': 'CNY',
            'direction': 'debit',
            'merchant': '校内商户',
          },
          {'time': '2026-07-26T09:00:00Z'},
        ],
      });
      expect(out, isNotNull);
      expect(out!.items, hasLength(1));
      expect(out.items.single.amountMinor, 850);
      expect(out.items.single.direction, 'debit');
    });

    test('负交易金额、非法币种或方向不进入 UI', () {
      final out = cardTransactionsFromDynamic({
        'cardNumber': '00000042',
        'items': [
          {
            'time': '2026-07-26T08:00:00Z',
            'amountMinor': -1,
            'currency': 'CNY',
            'direction': 'debit',
          },
          {
            'time': '2026-07-26T08:00:00Z',
            'amountMinor': 1,
            'currency': 'yuan',
            'direction': 'mystery',
          },
        ],
      });
      expect(out, isNotNull);
      expect(out!.items, isEmpty);
    });
  });

  group('examListFromDynamic', () {
    test('解出契约内可选字段与合法状态', () {
      final out = examListFromDynamic({
        'term': '2025-2026-2',
        'items': [
          {
            'courseId': 'TEST-201',
            'courseName': '离散数学',
            'examAt': '2026-08-10T01:00:00Z',
            'campus': '测试校区',
            'building': 'A 楼',
            'room': 'A-101',
            'seat': '08',
            'examType': '期末考试',
            'status': 'scheduled',
          },
        ],
      });

      expect(out, isNotNull);
      expect(out!.term, '2025-2026-2');
      expect(out.items, hasLength(1));
      expect(out.items!.single.courseName, '离散数学');
      expect(out.items!.single.status, 'scheduled');
      expect(out.items!.single.seat, '08');
    });

    test('items 可缺失；非法必填、状态或时间条目被过滤', () {
      expect(examListFromDynamic({})?.items, isNull);
      final out = examListFromDynamic({
        'items': [
          {'status': 'scheduled'},
          {'courseName': '课程一', 'status': 'invented'},
          {'courseName': '课程二', 'examAt': '2026-08-10'},
          {'courseName': '课程三', 'examAt': '2026-08-10 01:00:00Z'},
        ],
      });
      expect(out, isNotNull);
      expect(out!.items, isEmpty);
      expect(examListFromDynamic({'items': null}), isNull);
    });
  });

  group('libraryLoansFromDynamic', () {
    test('解出借阅条目、非负整数、布尔状态与费用', () {
      final out = libraryLoansFromDynamic({
        'items': [
          {
            'bookId': 'BOOK-001',
            'title': '测试图书',
            'author': '测试作者',
            'borrowedAt': '2026-07-01T00:00:00Z',
            'dueAt': '2026-08-31T23:59:59Z',
            'renewCount': 1,
            'renewalMax': 2,
            'renewable': true,
            'overdue': true,
            'overdueFee': {'amountMinor': 250, 'currency': 'CNY'},
          },
        ],
      });

      expect(out, isNotNull);
      expect(out!.items, hasLength(1));
      final loan = out.items.single;
      expect(loan.bookId, 'BOOK-001');
      expect(loan.renewCount, 1);
      expect(loan.renewable, isTrue);
      expect(loan.overdueFee?.amountMinor, 250);
      expect(loan.overdueFee?.currency, 'CNY');
    });

    test('缺顶层 items 返回 null；空 items 保留明确空列表', () {
      expect(libraryLoansFromDynamic({}), isNull);
      expect(libraryLoansFromDynamic({'items': []})?.items, isEmpty);
    });

    test('非法必填、时间、整数、币种或布尔类型条目被过滤', () {
      final out = libraryLoansFromDynamic({
        'items': [
          {
            'bookId': '',
            'title': '无效图书',
            'borrowedAt': '2026-07-01T00:00:00Z',
            'dueAt': '2026-08-31T23:59:59Z',
          },
          {
            'bookId': 'BOOK-002',
            'title': '无效时间',
            'borrowedAt': '2026-07-01',
            'dueAt': '2026-08-31T23:59:59Z',
          },
          {
            'bookId': 'BOOK-003',
            'title': '无效续借次数',
            'borrowedAt': '2026-07-01T00:00:00Z',
            'dueAt': '2026-08-31T23:59:59Z',
            'renewCount': '1',
          },
          {
            'bookId': 'BOOK-004',
            'title': '无效费用',
            'borrowedAt': '2026-07-01T00:00:00Z',
            'dueAt': '2026-08-31T23:59:59Z',
            'overdueFee': {'amountMinor': 1, 'currency': 'yuan'},
          },
          {
            'bookId': 'BOOK-005',
            'title': '无效状态',
            'borrowedAt': '2026-07-01T00:00:00Z',
            'dueAt': '2026-08-31T23:59:59Z',
            'overdue': 'yes',
          },
        ],
      });
      expect(out, isNotNull);
      expect(out!.items, isEmpty);
    });
  });
}
