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
  /// 成绩所属学年；缺失表示来源未提供。
  final String? academicYear;
  /// 学期的可读名称；缺失表示来源未提供。
  final String? termName;
  /// 成绩数据更新时间，RFC3339/UTC；缺失表示来源未提供。
  final String? updatedAt;
  /// 当前页码，从 1 开始；缺失表示未采用页码分页或来源未提供。
  final int? page;
  /// 每页条目数；缺失表示未采用页码分页或来源未提供。
  final int? size;
  /// 分页游标；缺失表示未采用游标分页或来源未提供。
  final String? cursor;
  /// 符合查询条件的成绩条目总数；缺失表示来源未提供。
  final int? total;
  /// 是否还有下一页成绩；缺失表示来源未提供。
  final bool? hasNext;
  /// 成绩条目列表。
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

  /// 校内作用域的课程标识。
  final String courseId;
  /// 课程名称。
  final String courseName;
  /// 课程学分数。
  final num credit;
  /// 学分类型；缺失表示来源未提供。
  final String? creditType;
  /// 学校定义的课程性质；缺失表示来源未提供。
  final String? courseNature;
  /// 学校定义的课程类别；缺失表示来源未提供。
  final String? courseCategory;
  /// 课程所属课程组；缺失表示来源未提供。
  final String? courseGroup;
  /// 课程教学语言；缺失表示来源未提供。
  final String? language;
  /// 任课教师；缺失表示来源未提供。
  final String? teacher;
  /// 课程开课单位；缺失表示来源未提供。
  final String? offeringUnit;
  /// 教学班号；缺失表示来源未提供。
  final String? classNo;
  /// 课程课序号；缺失表示来源未提供。
  final String? sectionNo;
  /// 课程考核方式；缺失表示来源未提供。
  final String? examMethod;
  /// 课程考试时刻，RFC3339/UTC；缺失表示来源未提供。
  final String? examAt;
  /// 该成绩是否来自重修；缺失表示来源未提供。
  final bool? retake;
  /// 学校来源中的成绩来源或状态：正常、重修、补考、缓考、免修、改分、退课或未知；缺失表示来源未提供。
  final String? sourceStatus;
  /// 该课程成绩排名，从 1 开始；缺失表示来源未提供。
  final int? rank;
  final GradesListItemsGradeDistribution? gradeDistribution;
  /// 该课程的平均成绩；缺失表示来源未提供。
  final num? courseAverage;
  /// 课程的归一化成绩值及其记分类型。
  final GradesListItemsScore score;
  /// 学校来源直接提供的课程绩点；计分尺度由来源学校定义，缺失表示来源未提供。
  final num? gradePoint;
  /// 跨校归一化课程类别：必修、选修或未知。
  final String category;
  /// 成绩发布状态：最终、暂定或未知。
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

  /// 成绩记分类型：数值、字母等级、通过/不通过或未知。
  final String kind;
  /// 按 kind 解释的归一化成绩值。
  final Object? value;
  /// 学校来源返回的原始成绩文本；缺失表示来源未提供。
  final String? raw;
  /// 成绩值状态：已知、未知、缺考、未发布或免修；缺失表示来源未提供。
  final String? status;
  /// 数值成绩的满分值；缺失表示来源未提供。
  final num? max;
}
