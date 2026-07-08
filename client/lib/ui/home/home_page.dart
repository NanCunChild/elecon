import 'package:flutter/material.dart';

class EleconHomePage extends StatefulWidget {
  const EleconHomePage({super.key, this.loadSnapshot});

  final Future<CampusSnapshot> Function()? loadSnapshot;

  @override
  State<EleconHomePage> createState() => _EleconHomePageState();
}

class _EleconHomePageState extends State<EleconHomePage> {
  late Future<CampusSnapshot> _snapshot;

  @override
  void initState() {
    super.initState();
    _snapshot = _load();
  }

  Future<CampusSnapshot> _load() {
    return widget.loadSnapshot?.call() ?? loadDemoCampusSnapshot();
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
                  error: state.error.toString(), onRetry: _reload);
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
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    sliver: SliverList.list(
                      children: [
                        _SnapshotHeader(snapshot: data),
                        const SizedBox(height: 12),
                        if (data.schedule != null) ScheduleCard(data.schedule!),
                        if (data.grades != null) GradesCard(data.grades!),
                        if (data.notices != null) NoticeCard(data.notices!),
                        for (final section in data.genericSections)
                          GenericSectionCard(section),
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

class CampusSnapshot {
  const CampusSnapshot({
    required this.schoolName,
    required this.updatedAt,
    this.grades,
    this.schedule,
    this.notices,
    this.genericSections = const [],
  });

  final String schoolName;
  final DateTime updatedAt;
  final GradesList? grades;
  final ScheduleWeek? schedule;
  final NoticeList? notices;
  final List<GenericSection> genericSections;

  bool get isEmpty =>
      grades == null &&
      schedule == null &&
      notices == null &&
      genericSections.isEmpty;
}

class GradesList {
  const GradesList({required this.term, required this.items});

  final String term;
  final List<GradeItem> items;
}

class GradeItem {
  const GradeItem({
    required this.courseName,
    required this.credit,
    required this.scoreText,
    required this.category,
    required this.status,
    this.gradePoint,
  });

  final String courseName;
  final num credit;
  final String scoreText;
  final String category;
  final String status;
  final num? gradePoint;
}

class ScheduleWeek {
  const ScheduleWeek(
      {required this.term, required this.week, required this.days});

  final String term;
  final int week;
  final List<ScheduleDay> days;
}

class ScheduleDay {
  const ScheduleDay({required this.dayOfWeek, required this.slots});

  final int dayOfWeek;
  final List<ScheduleSlot> slots;
}

class ScheduleSlot {
  const ScheduleSlot({
    required this.start,
    required this.end,
    required this.courseName,
    this.teacher,
    this.location,
  });

  final String start;
  final String end;
  final String courseName;
  final String? teacher;
  final String? location;
}

class NoticeList {
  const NoticeList({required this.items});

  final List<NoticeItem> items;
}

class NoticeItem {
  const NoticeItem({
    required this.title,
    required this.category,
    required this.source,
    this.summary,
    this.publishedAt,
  });

  final String title;
  final String category;
  final String source;
  final String? summary;
  final DateTime? publishedAt;
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
  const GenericField(
      {required this.label, required this.role, required this.value});

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

Future<CampusSnapshot> loadDemoCampusSnapshot() async {
  await Future<void>.delayed(const Duration(milliseconds: 350));
  return CampusSnapshot(
    schoolName: '示例大学',
    updatedAt: DateTime.utc(2026, 7, 6, 8, 30),
    schedule: const ScheduleWeek(
      term: '2025-2026-2',
      week: 18,
      days: [
        ScheduleDay(
          dayOfWeek: 1,
          slots: [
            ScheduleSlot(
              start: '08:30',
              end: '10:05',
              courseName: '数据结构',
              teacher: '李老师',
              location: 'A-301',
            ),
            ScheduleSlot(
              start: '14:00',
              end: '15:35',
              courseName: '大学英语',
              location: 'B-104',
            ),
          ],
        ),
        ScheduleDay(
          dayOfWeek: 3,
          slots: [
            ScheduleSlot(
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
        GradeItem(
          courseName: '高等数学',
          credit: 5,
          scoreText: '91',
          category: 'required',
          status: 'final',
          gradePoint: 4.1,
        ),
        GradeItem(
          courseName: '程序设计基础',
          credit: 4,
          scoreText: 'A',
          category: 'required',
          status: 'final',
          gradePoint: 4.3,
        ),
        GradeItem(
          courseName: '创新创业导论',
          credit: 1,
          scoreText: '通过',
          category: 'elective',
          status: 'final',
        ),
      ],
    ),
    notices: NoticeList(
      items: [
        NoticeItem(
          title: '期末考试周教学安排提醒',
          category: 'academic',
          source: '教务处',
          summary: '请同学们按准考证时间地点参加考试。',
          publishedAt: DateTime.utc(2026, 7, 3),
        ),
        NoticeItem(
          title: '暑期校园服务时间调整',
          category: 'admin',
          source: '学校办公室',
          publishedAt: DateTime.utc(2026, 7, 1),
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

class _SnapshotHeader extends StatelessWidget {
  const _SnapshotHeader({required this.snapshot});

  final CampusSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card.filled(
      child: Padding(
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
                leading:
                    CircleAvatar(child: Text('周${_weekText(day.dayOfWeek)}')),
                title: Text(slot.courseName),
                subtitle: Text([
                  '${slot.start}-${slot.end}',
                  if (slot.location != null) slot.location!,
                  if (slot.teacher != null) slot.teacher!,
                ].join(' · ')),
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
    final gpaItems =
        data.items.where((item) => item.gradePoint != null).toList();
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
              subtitle:
                  Text('${_categoryText(item.category)} · ${item.credit} 学分'),
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
              subtitle: Text([
                item.source,
                _noticeCategoryText(item.category),
                if (item.publishedAt != null) _formatDate(item.publishedAt!),
                if (item.summary != null) item.summary!,
              ].join(' · ')),
            ),
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
                      Text(_formatGenericValue(row[i], table.columns[i].role))),
              ],
            ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard(
      {required this.title, required this.subtitle, required this.child});

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
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
            Icon(Icons.error_outline,
                size: 40, color: Theme.of(context).colorScheme.error),
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
    GenericRole.identifier =>
      theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
    GenericRole.status =>
      theme.textTheme.bodyMedium?.copyWith(color: colorScheme.primary),
    GenericRole.deadline =>
      theme.textTheme.bodyMedium?.copyWith(color: colorScheme.error),
    GenericRole.amount =>
      theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
    GenericRole.quantity =>
      theme.textTheme.bodyMedium?.copyWith(color: colorScheme.secondary),
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
