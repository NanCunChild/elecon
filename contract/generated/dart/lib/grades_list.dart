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
    this.gradePointScale,
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
  /// 本次数据中 items[].gradePoint 所用的校本绩点尺度（满分档）。本体据此判断能否聚合，缺失/unknown/other 时不得展示聚合值（fail-closed，ADR-001 §3.5）。**只界定量纲，不保证跨校可比**：两所同称 4.0 制的学校，分数→绩点的换算表可能完全不同，故不得据此做跨校比较或排名。**other 与 unknown 含义不同**：other = adapter 知道制式但不在本枚举内（应视为扩枚举的信号）；unknown = adapter 无法判断（应视为该 adapter 待改进的信号）。**数据横跨学校改制时**（如部分课程 4.0、部分 4.3）不得任选其一，应声明 other 让本体降级。
  final String? gradePointScale;
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
    this.gradePointSource,
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
  /// 课程绩点；计分尺度由来源学校定义（见列表级 gradePointScale），来源直接给出或由 adapter 按校本换算规则派生（见 gradePointSource），缺失表示既未提供也无法派生。
  final num? gradePoint;
  /// gradePoint 的来源：source 表示学校来源直接给出，adapter-derived 表示 adapter 按校本换算规则派生，unknown 表示无法判断；缺失表示来源未提供该标注。
  final String? gradePointSource;
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
