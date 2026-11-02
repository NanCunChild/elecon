/// ADR-066: domain decoder preserving missing-value semantics.
library;

import '../models.dart';
import 'values.dart';

GpaSummary? gpaSummaryFromDynamic(Object? raw) {
  final map = asStringKeyedMap(raw);
  if (map == null) return null;
  return GpaSummary(
    gpa: map['gpa'] is num ? map['gpa'] as num : null,
    gradePointScale: map['gradePointScale']?.toString(),
    earnedCredits: map['earnedCredits'] is num
        ? map['earnedCredits'] as num
        : null,
    attemptedCredits: map['attemptedCredits'] is num
        ? map['attemptedCredits'] as num
        : null,
    rank: asInt(map['rank']),
    rankTotal: asInt(map['rankTotal']),
    window: map['window']?.toString(),
    updatedAt: map['updatedAt']?.toString(),
  );
}

// ---------------------------------------------------------------------------
// grades.list（ehall-session；App 内成绩单）
// ---------------------------------------------------------------------------

GradesList? gradesListFromDynamic(Object? raw) {
  final map = asStringKeyedMap(raw);
  if (map == null) return null;
  final term = map['term']?.toString();
  if (term == null || term.isEmpty) return null;
  final itemsRaw = map['items'];
  if (itemsRaw is! List) return null;
  final items = <GradesListItems>[];
  for (final entry in itemsRaw) {
    final item = _gradeItem(entry);
    if (item != null) items.add(item);
  }
  return GradesList(
    term: term,
    academicYear: map['academicYear']?.toString(),
    termName: map['termName']?.toString(),
    updatedAt: map['updatedAt']?.toString(),
    total: asInt(map['total']),
    hasNext: map['hasNext'] is bool ? map['hasNext'] as bool : null,
    gradePointScale: map['gradePointScale']?.toString(),
    items: items,
  );
}

GradesListItems? _gradeItem(Object? raw) {
  final map = asStringKeyedMap(raw);
  if (map == null) return null;
  final courseId = map['courseId']?.toString();
  final courseName = map['courseName']?.toString();
  final credit = map['credit'];
  final category = map['category']?.toString();
  final status = map['status']?.toString();
  final score = _gradeScore(map['score']);
  if (courseId == null ||
      courseId.isEmpty ||
      courseName == null ||
      courseName.isEmpty ||
      credit is! num ||
      category == null ||
      category.isEmpty ||
      status == null ||
      status.isEmpty ||
      score == null) {
    return null;
  }
  return GradesListItems(
    courseId: courseId,
    courseName: courseName,
    credit: credit,
    creditType: map['creditType']?.toString(),
    courseNature: map['courseNature']?.toString(),
    courseCategory: map['courseCategory']?.toString(),
    teacher: map['teacher']?.toString(),
    offeringUnit: map['offeringUnit']?.toString(),
    classNo: map['classNo']?.toString(),
    examMethod: map['examMethod']?.toString(),
    examAt: map['examAt']?.toString(),
    retake: map['retake'] is bool ? map['retake'] as bool : null,
    sourceStatus: map['sourceStatus']?.toString(),
    rank: asInt(map['rank']),
    courseAverage: map['courseAverage'] is num
        ? map['courseAverage'] as num
        : null,
    score: score,
    gradePoint: map['gradePoint'] is num ? map['gradePoint'] as num : null,
    gradePointSource: map['gradePointSource']?.toString(),
    category: category,
    status: status,
  );
}

GradesListItemsScore? _gradeScore(Object? raw) {
  final map = asStringKeyedMap(raw);
  if (map == null) return null;
  final kind = map['kind']?.toString();
  if (kind == null || kind.isEmpty) return null;
  // value 契约允许 number / string / null（通过制或缺考），原样透传，不臆造。
  return GradesListItemsScore(
    kind: kind,
    value: map['value'],
    raw: map['raw']?.toString(),
    status: map['status']?.toString(),
    max: map['max'] is num ? map['max'] as num : null,
  );
}
