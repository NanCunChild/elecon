import 'package:flutter/material.dart';
import '../../l10n/gen/app_localizations.dart';
import 'models.dart';
import 'capability_source.dart';
import 'section_card.dart';
import 'card_preview_list.dart';
import 'display_date.dart';
import 'notice_detail_page.dart';
import 'notice_summary.dart';

class GradesCard extends StatelessWidget {
  const GradesCard(
    this.data, {
    this.summary,
    this.trailing,
    this.controls,
    super.key,
  });
  final Widget? trailing;
  final Widget? controls;

  final GradesList data;

  /// 学校官方绩点汇总（`gpa.summary`）。**存在即权威**——本体不得用自算值覆盖
  /// 或"修正"它（ADR-001 §3.5 优先级规则第 1 条）。null 表示该校未提供或未取到。
  final GpaSummary? summary;

  /// 本机聚合（ADR-001 §3.5「跨校统一的派生 → 本体」）。
  ///
  /// **只在没有官方汇总、或用户施加了筛选时才用**（优先级规则第 2 条），且展示时
  /// **必须与官方数用不同标签**（第 3 条）——两个不同的数都叫 GPA 比不显示更糟。
  ///
  /// **fail-closed**：`gradePointScale` 缺失或不可聚合时返回 null，卡片不展示。
  /// 课程级 `gradePoint` 的换算是校本的（adapter 的活），本体只在**知道满分档**
  /// 时才敢把它们加权平均——否则展示的数没有任何学校意义。
  double? _aggregateGpa() {
    final scale = data.gradePointScale;
    if (scale == null || !_aggregatableScales.contains(scale)) return null;
    var weightedPoints = 0.0;
    var totalCredits = 0.0;
    for (final item in data.items) {
      if (item.gradePoint == null || item.credit <= 0) continue;
      weightedPoints += item.gradePoint! * item.credit;
      totalCredits += item.credit;
    }
    if (totalCredits <= 0) return null;
    final gpa = weightedPoints / totalCredits;
    return gpa.isFinite ? gpa : null;
  }

  /// 可聚合的校本绩点尺度（ADR-001 §3.5）。`other` / `unknown` / 缺失都不可聚合：
  /// 不同满分档的绩点混算出的数不是任何学校意义上的 GPA。
  static const _aggregatableScales = <String>{'4.0', '4.3', '4.5', '5.0'};

  /// 副标题的绩点段。**官方数优先**；没有官方数才退到本机聚合，且换标签。
  ///
  /// 两路都对 `gradePointScale` fail-closed：尺度缺失 / `unknown` / `other` 一律不展示
  /// （ADR-001 §3.5）。官方数的尺度取自 `gpa.summary` 自身，不借用 `grades.list` 的——
  /// 两者可能覆盖不同范围，混用尺度等于给一个数贴错量纲。
  String? _gradePointText() {
    final official = summary?.gpa;
    final officialScale = summary?.gradePointScale;
    if (official != null &&
        officialScale != null &&
        _aggregatableScales.contains(officialScale)) {
      return 'GPA ${official.toStringAsFixed(2)}（$officialScale 制）';
    }
    final local = _aggregateGpa();
    if (local == null) return null;
    // 标签必须与官方「GPA」可分（优先级规则第 3 条）。
    return '均绩 ${local.toStringAsFixed(2)}'
        '（${data.gradePointScale} 制 · 本机计算）';
  }

  @override
  Widget build(BuildContext context) {
    final gradePointText = _gradePointText();
    return SectionCard(
      title: '成绩',
      trailing: trailing,
      subtitle:
          '${data.term}${gradePointText == null ? '' : ' · $gradePointText'}',
      summary: CardSummary(
        gradePointText ?? data.items.firstOrNull?.scoreText ?? '—',
        detail: [
          data.term,
          if (gradePointText == null && data.items.isNotEmpty)
            data.items.first.courseName,
        ].join(' · '),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ?controls,
          CardPreviewList(
            title: '成绩',
            children: [
              if (data.items.isEmpty)
                Text(AppLocalizations.of(context).gradesEmpty),
              for (final item in data.items)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(item.courseName),
                  subtitle: Text(
                    '${_categoryText(item.category)} · ${item.credit} 学分',
                  ),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        item.scoreText,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(_statusText(item.status)),
                    ],
                  ),
                  // App 内下钻：由课程标识 + 本详情视图闸门，不依赖外链（ADR-025 §2.6）。
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          CourseDetailPage(item: item, term: data.term),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class NoticeCard extends StatelessWidget {
  const NoticeCard(
    this.data, {
    super.key,
    this.trailing,
    this.status,
    this.statusSummary,
  });
  final Widget? trailing;
  final Widget? status;
  final Widget? statusSummary;

  final NoticeList data;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SectionCard(
      title: l10n.homeNoticeTitle,
      trailing: trailing,
      subtitle: l10n.homeNoticeCount(data.items.length),
      summary: statusSummary ?? NoticeSummary(items: data.items),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (status != null)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: status!),
          CardPreviewList(
            title: l10n.homeNoticeTitle,
            children: [
              for (final item in data.items)
                Column(
                  children: [
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                      title: Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 6),
                          Text(
                            [
                                  item.source,
                                  _noticeCategoryText(l10n, item.category),
                                  // 契约 publishedAt 为 RFC3339 字符串；经视图扩展转 DateTime 展示。
                                  if (item.publishedAtDateTime != null)
                                    formatLocalDate(item.publishedAtDateTime!),
                                ]
                                .map((value) => value.trim())
                                .where((value) => value.isNotEmpty)
                                .join(' · '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                          if (item.summary?.trim().isNotEmpty == true) ...[
                            const SizedBox(height: 6),
                            Text(
                              item.summary!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      // App 内下钻：由通知标识 + 本详情视图闸门，不依赖外链（ADR-025 §2.6）。
                      onTap: () {
                        final source = CapabilitySourceScope.maybeOf(
                          context,
                        )?.source;
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                NoticeDetailPage(item: item, source: source),
                          ),
                        );
                      },
                    ),
                    if (item != data.items.last) const Divider(height: 1),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 成绩单课详情（App 内下钻，ADR-025 §2.2/§2.6）。
///
/// 仅渲染快照中已有的课程数据，**不发起任何网络请求、不涉外链**（外跳属 §2.7，
/// 触红线 #1，另行落地）。字段一律 schema 既有，缺失即不展示（红线 #6，不臆造）。
class CourseDetailPage extends StatelessWidget {
  const CourseDetailPage({required this.item, required this.term, super.key});

  final GradesListItems item;
  final String term;

  @override
  Widget build(BuildContext context) {
    final examAt = item.examAt == null ? null : DateTime.tryParse(item.examAt!);
    final rows = <Widget>[
      _DetailRow(label: '课程名称', value: item.courseName),
      _DetailRow(label: '课程号', value: item.courseId),
      _DetailRow(label: '学期', value: term),
      _DetailRow(label: '学分', value: '${item.credit}'),
      _DetailRow(label: '类别', value: _categoryText(item.category)),
      _DetailRow(
        label: '成绩',
        value: item.scoreText.isEmpty ? '未发布' : item.scoreText,
      ),
      if (item.gradePoint != null)
        _DetailRow(
          label: '绩点',
          // gradePointSource 让「学校给的」与「adapter 按校本规则推算的」可分辨
          // （ADR-001 §3.5）；缺失即来源未标注，不臆断。
          value: item.gradePointSource == 'adapter-derived'
              ? '${item.gradePoint}（推算）'
              : '${item.gradePoint}',
        ),
      _DetailRow(label: '状态', value: _statusText(item.status)),
      if (item.teacher != null) _DetailRow(label: '任课教师', value: item.teacher!),
      if (item.offeringUnit != null)
        _DetailRow(label: '开课单位', value: item.offeringUnit!),
      if (item.classNo != null) _DetailRow(label: '教学班', value: item.classNo!),
      if (item.examMethod != null)
        _DetailRow(label: '考核方式', value: item.examMethod!),
      if (examAt != null)
        _DetailRow(label: '考试时间', value: formatLocalDateTime(examAt)),
      if (item.rank != null) _DetailRow(label: '课程排名', value: '${item.rank}'),
      if (item.courseAverage != null)
        _DetailRow(label: '课程平均分', value: '${item.courseAverage}'),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(item.courseName)),
      body: ListView(padding: const EdgeInsets.all(16), children: rows),
    );
  }
}

/// 详情页的「标签 + 值」明细行。
class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

String _categoryText(String category) => switch (category) {
  'required' => '必修',
  'elective' => '选修',
  _ => '未知类别',
};

String _statusText(String status) => switch (status) {
  'final' => '已确认',
  'provisional' => '暂定',
  _ => '未知',
};

String _noticeCategoryText(AppLocalizations l10n, String category) =>
    switch (category) {
      'academic' => l10n.homeNoticeCategoryAcademic,
      'admin' => l10n.homeNoticeCategoryAdmin,
      'event' => l10n.homeNoticeCategoryEvent,
      _ => l10n.homeNoticeCategoryOther,
    };

class GenericSectionCard extends StatelessWidget {
  const GenericSectionCard(this.section, {super.key, this.trailing});
  final Widget? trailing;

  final GenericSection section;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: section.title,
      trailing: trailing,
      summary: section.fields.isEmpty
          ? (section.table == null
                ? null
                : CardSummary(
                    AppLocalizations.of(
                      context,
                    ).homeCardTableRows(section.table!.rows.length),
                    detail: section.table!.columns
                        .map((c) => c.label)
                        .join(' · '),
                  ))
          : CardSummary(
              _formatGenericValue(
                section.fields.first.value,
                section.fields.first.role,
              ),
              detail: section.fields.first.label,
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (section.fields.isNotEmpty) _GenericFields(fields: section.fields),
          if (section.table != null) _GenericTableView(table: section.table!),
        ],
      ),
    );
  }
}

class _GenericFields extends StatelessWidget {
  const _GenericFields({required this.fields});

  final List<GenericField> fields;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final field in fields)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: OverflowBar(
              alignment: MainAxisAlignment.spaceBetween,
              spacing: 16,
              overflowSpacing: 4,
              children: [
                Text(field.label),
                Text(
                  _formatGenericValue(field.value, field.role),
                  style: _roleTextStyle(context, field.role),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _GenericTableView extends StatelessWidget {
  const _GenericTableView({required this.table});

  final GenericTable table;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: [
          for (final column in table.columns)
            DataColumn(label: Text(column.label)),
        ],
        rows: [
          for (final row in table.rows)
            DataRow(
              cells: [
                for (var i = 0; i < table.columns.length; i++)
                  DataCell(
                    Text(_formatGenericValue(row[i], table.columns[i].role)),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

TextStyle? _roleTextStyle(BuildContext context, GenericRole role) {
  final theme = Theme.of(context);
  final colorScheme = theme.colorScheme;
  return switch (role) {
    GenericRole.identifier => theme.textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w700,
    ),
    GenericRole.status => theme.textTheme.bodyMedium?.copyWith(
      color: colorScheme.primary,
    ),
    GenericRole.deadline => theme.textTheme.bodyMedium?.copyWith(
      color: colorScheme.error,
    ),
    GenericRole.amount => theme.textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w700,
    ),
    GenericRole.quantity => theme.textTheme.bodyMedium?.copyWith(
      color: colorScheme.secondary,
    ),
    GenericRole.link => theme.textTheme.bodyMedium?.copyWith(
      color: colorScheme.primary,
      decoration: TextDecoration.underline,
    ),
    _ => theme.textTheme.bodyMedium,
  };
}

String _formatGenericValue(Object? value, GenericRole role) {
  if (value == null) return '未提供';
  if (role == GenericRole.amount && value is int) {
    return '¥${(value / 100).toStringAsFixed(2)}';
  }
  if ((role == GenericRole.datetime || role == GenericRole.deadline) &&
      value is DateTime) {
    return formatLocalDateTime(value);
  }
  return value.toString();
}
