/// 首页数据模型（view model 层）。
///
/// **schema 权威类型来自 codegen 产物包 `elecon_contract`**（contract/schema 单源，
/// 红线 #6），此处 re-export 供 UI 消费——原「手写模型与 schema 漂移」TODO 已兑现
/// （审阅 P0-1）。本文件仅保留非契约的视图层内容：
///  - [CampusSnapshot]：UI 聚合视图（多契约对象 + 展示元信息），非 schema 对象；
///  - Generic*：`generic.section.schema.json` 含 oneOf，codegen 明确跳过（不静默
///    生成错类型），此处人工维护，schema 变更须同步；
///  - 展示辅助扩展（[GradesScoreText] / [NoticePublishedAt]）：视图格式化，非契约。
library;

import 'package:elecon_contract/grades_list.dart';
import 'package:elecon_contract/notice_list.dart';
import 'package:elecon_contract/schedule_week.dart' show ScheduleWeek;

export 'package:elecon_contract/classroom_available.dart';
export 'package:elecon_contract/classroom_buildings.dart';
export 'package:elecon_contract/card_balance.dart';
export 'package:elecon_contract/card_transactions.dart';
export 'package:elecon_contract/exam_list.dart';
export 'package:elecon_contract/grades_list.dart';
export 'package:elecon_contract/library_loans.dart';
export 'package:elecon_contract/notice_list.dart';
export 'package:elecon_contract/schedule_week.dart';

class CampusSnapshot {
  const CampusSnapshot({
    required this.schoolName,
    required this.updatedAt,
    this.grades,
    this.schedule,
    this.notices,
    this.genericSections = const [],
    this.supportedCapabilities = const <String>{},
  });

  final String schoolName;
  final DateTime updatedAt;
  final GradesList? grades;
  final ScheduleWeek? schedule;
  final NoticeList? notices;
  final List<GenericSection> genericSections;
  final Set<String> supportedCapabilities;

  bool supportsAll(Iterable<String> capabilities) =>
      capabilities.every(supportedCapabilities.contains);

  bool get isEmpty =>
      grades == null &&
      schedule == null &&
      notices == null &&
      genericSections.isEmpty;
}

/// 成绩展示文本：契约 score `{kind, value, max}` → 视图字符串（值原样呈现，
/// 数值/字母/通过制均由 adapter 归一进 value）。
extension GradesScoreText on GradesListItems {
  String get scoreText => score.value?.toString() ?? '';
}

/// 通知发布时间：契约为 RFC3339 字符串（可选）→ [DateTime]；缺失或不可解析为 null。
extension NoticePublishedAt on NoticeListItems {
  DateTime? get publishedAtDateTime {
    final s = publishedAt;
    return s == null ? null : DateTime.tryParse(s);
  }
}

class GenericSection {
  const GenericSection({
    required this.sectionId,
    required this.title,
    this.fields = const [],
    this.table,
  });

  final String sectionId;
  final String title;
  final List<GenericField> fields;
  final GenericTable? table;
}

class GenericField {
  const GenericField({
    required this.label,
    required this.role,
    required this.value,
  });

  final String label;
  final GenericRole role;
  final Object? value;
}

class GenericTable {
  const GenericTable({required this.columns, required this.rows});

  final List<GenericColumn> columns;
  final List<List<Object?>> rows;
}

class GenericColumn {
  const GenericColumn({required this.label, required this.role});

  final String label;
  final GenericRole role;
}

enum GenericRole {
  identifier,
  label,
  status,
  datetime,
  deadline,
  amount,
  quantity,
  link,
  unknown,
}
