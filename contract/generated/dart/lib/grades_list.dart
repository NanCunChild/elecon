// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class GradesList {
  const GradesList({
    required this.term,
    this.academicYear,
    this.termName,
    this.updatedAt,
    this.page,
    this.size,
    this.cursor,
    this.total,
    this.hasNext,
    required this.items,
  });

  /// 学期标识，如 2025-2026-2
  final String term;
  final String? academicYear;
  final String? termName;
  final String? updatedAt;
  final int? page;
  final int? size;
  final String? cursor;
  final int? total;
  final bool? hasNext;
  final List<GradesListItems> items;
}

class GradesListItems {
  const GradesListItems({
    required this.courseId,
    required this.courseName,
    required this.credit,
    this.creditType,
    this.courseNature,
    this.courseCategory,
    this.courseGroup,
    this.language,
    this.teacher,
    this.offeringUnit,
    this.classNo,
    this.sectionNo,
    this.examMethod,
    this.examAt,
    this.retake,
    this.sourceStatus,
    this.rank,
    this.gradeDistribution,
    this.courseAverage,
    required this.score,
    this.gradePoint,
    required this.category,
    required this.status,
  });

  final String courseId;
  final String courseName;
  final num credit;
  final String? creditType;
  final String? courseNature;
  final String? courseCategory;
  final String? courseGroup;
  final String? language;
  final String? teacher;
  final String? offeringUnit;
  final String? classNo;
  final String? sectionNo;
  final String? examMethod;
  final String? examAt;
  final bool? retake;
  final String? sourceStatus;
  final int? rank;
  final GradesListItemsGradeDistribution? gradeDistribution;
  final num? courseAverage;
  final GradesListItemsScore score;
  final num? gradePoint;
  final String category;
  final String status;
}

class GradesListItemsGradeDistribution {
  const GradesListItemsGradeDistribution();

}

class GradesListItemsScore {
  const GradesListItemsScore({
    required this.kind,
    required this.value,
    this.raw,
    this.status,
    this.max,
  });

  final String kind;
  final Object? value;
  final String? raw;
  final String? status;
  final num? max;
}
