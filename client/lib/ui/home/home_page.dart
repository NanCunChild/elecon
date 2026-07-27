/// elecon 首页：把核心/adapter 产出的 [CampusSnapshot] 渲染为卡片流。
///
/// 默认经 [SessionScope] 跑 `notice.list` 真数据（MVP-A）；可注入 [loadSnapshot] 覆盖（测试/demo）。
/// 数据模型见 `models.dart`；`demo_data.dart` 仍 export 供调试占位。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../session/session_scope.dart';
import '../theme/liquid_glass.dart';
import 'campus_snapshot_loader.dart';
import 'capability_sections.dart';
import 'demo_data.dart';
import 'models.dart';

export 'demo_data.dart';
export 'models.dart';

/// debug 下强制走 demo 快照（设置/联调开关可后接；默认 false = 真数据）。
const bool kForceDemoHomeSnapshot = false;

class EleconHomePage extends StatefulWidget {
  const EleconHomePage({super.key, this.loadSnapshot});

  final Future<CampusSnapshot> Function()? loadSnapshot;

  @override
  State<EleconHomePage> createState() => _EleconHomePageState();
}

class _EleconHomePageState extends State<EleconHomePage> {
  late Future<CampusSnapshot> _snapshot;
  var _bound = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_bound) {
      _bound = true;
      _snapshot = _load();
    }
  }

  /// 是否装配按需取数区：仅真数据模式（无注入、无 demo）——否则无 [SessionScope]。
  bool get _liveSections =>
      widget.loadSnapshot == null && !(kDebugMode && kForceDemoHomeSnapshot);

  Future<CampusSnapshot> _load() {
    if (widget.loadSnapshot != null) return widget.loadSnapshot!();
    if (kDebugMode && kForceDemoHomeSnapshot) {
      return loadDemoCampusSnapshot();
    }
    return loadCampusSnapshot(SessionScope.of(context));
  }

  void _reload() {
    setState(() => _snapshot = _load());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: FutureBuilder<CampusSnapshot>(
          future: _snapshot,
          builder: (context, state) {
            if (state.connectionState != ConnectionState.done) {
              return const _LoadingState();
            }
            if (state.hasError) {
              return _ErrorState(
                error: state.error.toString(),
                onRetry: _reload,
              );
            }
            final data = state.data;
            if (data == null || data.isEmpty) {
              return _EmptyState(onRetry: _reload);
            }
            return RefreshIndicator(
              onRefresh: () async => _reload(),
              child: CustomScrollView(
                slivers: [
                  SliverAppBar.large(
                    title: const Text('elecon'),
                    actions: [
                      IconButton(
                        tooltip: '刷新',
                        onPressed: _reload,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      0,
                      16,
                      liquidGlassEnabled(context) ? 100 : 24,
                    ),
                    sliver: SliverList.list(
                      children: [
                        _SnapshotHeader(snapshot: data),
                        const SizedBox(height: 12),
                        if (data.schedule != null) ScheduleCard(data.schedule!),
                        if (data.grades != null) GradesCard(data.grades!),
                        if (data.notices != null) NoticeCard(data.notices!),
                        for (final section in data.genericSections)
                          GenericSectionCard(section),
                        // 按需取数区（需 ehall-session；点击触发静默 mint / 可见登录）。
                        // 仅真数据模式装配——注入 loadSnapshot（测试）或 demo 快照时不挂，
                        // 避免无 SessionScope 语境崩溃。
                        if (_liveSections &&
                            data.supportsAll(const ['card.balance']))
                          CardSection(
                            transactionsEnabled: data.supportsAll(const [
                              'card.transactions',
                            ]),
                          ),
                        if (_liveSections &&
                            data.supportsAll(const ['grades.list']))
                          const GradesSection(),
                        if (_liveSections &&
                            data.supportsAll(const ['schedule.week']))
                          const ScheduleSection(),
                        if (_liveSections &&
                            data.supportsAll(const [
                              'classroom.buildings',
                              'classroom.available',
                            ]))
                          const ClassroomSection(),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SnapshotHeader extends StatelessWidget {
  const _SnapshotHeader({required this.snapshot});

  final CampusSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LiquidGlassSurface(
      borderRadius: 16,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('你好，校园信息已就绪', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            '${snapshot.schoolName} · ${_formatDateTime(snapshot.updatedAt)} 更新',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class ScheduleCard extends StatelessWidget {
  const ScheduleCard(this.data, {super.key});

  final ScheduleWeek data;

  @override
  Widget build(BuildContext context) {
    final count = data.days.fold<int>(0, (sum, day) => sum + day.slots.length);
    return _SectionCard(
      title: '本周课表',
      subtitle: '${data.term} · 第 ${data.week} 周 · $count 节课',
      child: Column(
        children: [
          for (final day in data.days)
            for (final slot in day.slots)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  child: Text('周${_weekText(day.dayOfWeek)}'),
                ),
                title: Text(slot.courseName),
                subtitle: Text(
                  [
                    '${slot.start}-${slot.end}',
                    if (slot.location != null) slot.location!,
                    if (slot.teacher != null) slot.teacher!,
                  ].join(' · '),
                ),
              ),
        ],
      ),
    );
  }
}

class GradesCard extends StatelessWidget {
  const GradesCard(this.data, {super.key});

  final GradesList data;

  @override
  Widget build(BuildContext context) {
    final gpaItems = data.items
        .where((item) => item.gradePoint != null)
        .toList();
    final gpa = gpaItems.isEmpty
        ? null
        : gpaItems
                  .map((item) => item.gradePoint! * item.credit)
                  .reduce((a, b) => a + b) /
              gpaItems.map((item) => item.credit).reduce((a, b) => a + b);
    return _SectionCard(
      title: '成绩',
      subtitle:
          '${data.term}${gpa == null ? '' : ' · GPA ${gpa.toStringAsFixed(2)}'}',
      child: Column(
        children: [
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
                  builder: (_) => CourseDetailPage(item: item, term: data.term),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class NoticeCard extends StatelessWidget {
  const NoticeCard(this.data, {super.key});

  final NoticeList data;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: '通知',
      subtitle: '${data.items.length} 条最新消息',
      child: Column(
        children: [
          for (final item in data.items)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(item.title),
              subtitle: Text(
                [
                  item.source,
                  _noticeCategoryText(item.category),
                  // 契约 publishedAt 为 RFC3339 字符串；经视图扩展转 DateTime 展示。
                  if (item.publishedAtDateTime != null)
                    _formatDate(item.publishedAtDateTime!),
                  if (item.summary != null) item.summary!,
                ].join(' · '),
              ),
              trailing: const Icon(Icons.chevron_right),
              // App 内下钻：由通知标识 + 本详情视图闸门，不依赖外链（ADR-025 §2.6）。
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => NoticeDetailPage(item: item),
                ),
              ),
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
        _DetailRow(label: '绩点', value: '${item.gradePoint}'),
      _DetailRow(label: '状态', value: _statusText(item.status)),
      if (item.teacher != null) _DetailRow(label: '任课教师', value: item.teacher!),
      if (item.offeringUnit != null)
        _DetailRow(label: '开课单位', value: item.offeringUnit!),
      if (item.classNo != null) _DetailRow(label: '教学班', value: item.classNo!),
      if (item.examMethod != null)
        _DetailRow(label: '考核方式', value: item.examMethod!),
      if (examAt != null)
        _DetailRow(label: '考试时间', value: _formatDateTime(examAt)),
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

/// 通知正文详情（App 内下钻，ADR-025 §2.2/§2.6）。
///
/// 仅渲染快照数据；正文按纯文本展示（不解析 HTML，属 ADR-011 范畴）。附件与「在网页
/// 打开」属外跳（§2.7，触红线 #1），本轮不接线、不可点。
class NoticeDetailPage extends StatelessWidget {
  const NoticeDetailPage({required this.item, super.key});

  final NoticeListItems item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = <String>[
      item.source,
      _noticeCategoryText(item.category),
      if (item.author != null) item.author!,
      if (item.department != null) item.department!,
      if (item.publishedAtDateTime != null)
        _formatDate(item.publishedAtDateTime!),
    ].join(' · ');
    final attachments =
        item.attachments ?? const <NoticeListItemsAttachments>[];
    final hasContent = item.content != null && item.content!.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('通知详情')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(item.title, style: theme.textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            meta,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const Divider(height: 24),
          if (item.summary != null && item.summary!.isNotEmpty) ...[
            Text(item.summary!, style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
          ],
          Text(
            hasContent ? item.content! : '（本条通知未提供正文）',
            style: theme.textTheme.bodyMedium,
          ),
          if (attachments.isNotEmpty) ...[
            const Divider(height: 24),
            Text('附件', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            for (final a in attachments)
              // 附件打开需外跳（§2.7 凭证隔离，触红线 #1），本轮未接线故禁用点击。
              ListTile(
                contentPadding: EdgeInsets.zero,
                enabled: false,
                leading: const Icon(Icons.attach_file),
                title: Text(a.name),
              ),
          ],
        ],
      ),
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

class GenericSectionCard extends StatelessWidget {
  const GenericSectionCard(this.section, {super.key});

  final GenericSection section;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: section.title,
      subtitle: '通用模板 · ${section.sectionId}',
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
            child: Row(
              children: [
                Expanded(child: Text(field.label)),
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

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LiquidGlassSurface(
      margin: const EdgeInsets.only(bottom: 12),
      borderRadius: 16,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('正在加载校园信息...'),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error, required this.onRetry});

  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 40,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            const Text('加载失败'),
            const SizedBox(height: 8),
            Text(error, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.inbox_outlined, size: 40),
          const SizedBox(height: 12),
          const Text('暂无可展示数据'),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: onRetry, child: const Text('刷新')),
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
    return _formatDateTime(value);
  }
  return value.toString();
}

String _formatDate(DateTime date) =>
    '${date.year}-${_two(date.month)}-${_two(date.day)}';

String _formatDateTime(DateTime date) =>
    '${_formatDate(date)} ${_two(date.hour)}:${_two(date.minute)}';

String _two(int value) => value.toString().padLeft(2, '0');

String _weekText(int day) => switch (day) {
  1 => '一',
  2 => '二',
  3 => '三',
  4 => '四',
  5 => '五',
  6 => '六',
  7 => '日',
  _ => '?',
};

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

String _noticeCategoryText(String category) => switch (category) {
  'academic' => '教学',
  'admin' => '行政',
  'event' => '活动',
  _ => '其他',
};
