/// elecon 首页：把核心/adapter 产出的 [CampusSnapshot] 渲染为卡片流。
///
/// 默认经 [SessionScope] 跑 `notice.list` 真数据（MVP-A）；可注入 [loadSnapshot] 覆盖（测试/demo）。
/// 数据模型见 `models.dart`；`demo_data.dart` 仍 export 供调试占位。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../session/session_scope.dart';
import '../../core/scripts/manifest.dart';
import '../../session/session_controller.dart';
import '../../l10n/gen/app_localizations.dart';
import '../theme/liquid_glass.dart';
import 'campus_snapshot_loader.dart';
import 'card_layout.dart';
import 'card_layout_store.dart';
import 'card_preview_list.dart';
import 'editable_card_board.dart';
import 'capability_sections.dart';
import 'demo_data.dart';
import 'display_date.dart';
import 'models.dart';
import 'notice_detail_page.dart';
import 'section_card.dart';
import 'schedule_view.dart';
export 'schedule_view.dart' show ScheduleCard;
import 'energy_climate_sections.dart';
import 'faculty_search_section.dart';

export 'demo_data.dart';
export 'models.dart';
export 'notice_detail_page.dart';

/// debug 下强制走 demo 快照（设置/联调开关可后接；默认 false = 真数据）。
const bool kForceDemoHomeSnapshot = false;

typedef CampusSnapshotLoader = Future<CampusSnapshot> Function();

class EleconHomePage extends StatefulWidget {
  const EleconHomePage({super.key, this.loadSnapshot, this.layoutStore});

  final CampusSnapshotLoader? loadSnapshot;
  final CardLayoutStore? layoutStore;

  @override
  State<EleconHomePage> createState() => _EleconHomePageState();
}

class _EleconHomePageState extends State<EleconHomePage>
    with WidgetsBindingObserver {
  late Future<CampusSnapshot> _snapshot;
  var _bound = false;
  SessionController? _session;
  String? _school;
  int? _revision;
  int? _generation;
  CampusSnapshot? _lastSnapshot;
  Timer? _homeRefreshTimer;
  Map<String, HomeCardSize> _cardDefaults = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _homeRefreshTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _homeRefreshTimer?.cancel();
    if (state == AppLifecycleState.resumed) {
      _scheduleHomeRefresh();
      unawaited(_refreshSilently());
    }
  }

  void _scheduleHomeRefresh() {
    _homeRefreshTimer?.cancel();
    if (_session == null) return;
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null && state != AppLifecycleState.resumed) return;
    // ADR-038: while the app remains visible, TTL checks can refresh values
    // without adding foreground animation or opening interactive presenters.
    _homeRefreshTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) unawaited(_refreshSilently());
    });
  }

  Future<void> _refreshSilently({bool force = false}) async {
    try {
      await _session?.refreshHomeData(force: force);
    } catch (_) {
      // ADR-038: background failures retain the original successful values.
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_liveSections) {
      final session = SessionScope.of(context);
      final changed =
          _session != session ||
          _school != session.selectedSchool?.id ||
          _generation != session.trustedScriptViewGeneration;
      if (changed) {
        _session = session;
        _school = session.selectedSchool?.id;
        _generation = session.trustedScriptViewGeneration;
        _lastSnapshot = null;
        _cardDefaults = {};
        unawaited(_loadCardDefaults(session));
      }
      if (!_bound || changed || _revision != session.homeDataRevision) {
        _revision = session.homeDataRevision;
        _bound = true;
        _snapshot = _load();
      }
      if (changed) {
        _scheduleHomeRefresh();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_refreshSilently());
        });
      }
    } else if (!_bound) {
      _bound = true;
      _snapshot = _load();
    }
  }

  Future<void> _loadCardDefaults(SessionController session) async {
    final school = session.selectedSchool?.id;
    final generation = session.trustedScriptViewGeneration;
    if (school == null) return;
    try {
      final registry = await session.scriptRegistry;
      final defaults = <String, HomeCardSize>{};
      for (final entry in ScriptCardEntry.requiredCapabilitiesByType.entries) {
        final package = registry.baseProvider(school, entry.value.first);
        if (package == null) continue;
        for (final card in package.manifest.cards) {
          if (card.type != entry.key) continue;
          // SDK 6 retains its original preview meanings; local layout v2
          // maps those suggestions without reinterpreting the package.
          defaults[card.type] = card.defaultVariant == 'compact'
              ? HomeCardSize.regular
              : HomeCardSize.expanded;
        }
      }
      if (mounted &&
          identical(session, _session) &&
          school == _school &&
          generation == _generation) {
        setState(() => _cardDefaults = defaults);
      }
    } catch (_) {
      // Presentation suggestions are optional; local user choices still apply.
    }
  }

  List<HomeCardEntry> _cards(CampusSnapshot data) {
    final l10n = AppLocalizations.of(context);
    HomeCardEntry entry(
      String id,
      String label,
      WidgetBuilder builder, {
      String? type,
    }) => HomeCardEntry(
      id: id,
      label: label,
      builder: builder,
      icon: switch (type ?? id) {
        'notice' => Icons.campaign_outlined,
        'schedule' => Icons.calendar_month_outlined,
        'grades' => Icons.school_outlined,
        'library' => Icons.menu_book_outlined,
        'card' => Icons.account_balance_wallet_outlined,
        'exam' => Icons.event_note_outlined,
        'classroom' => Icons.meeting_room_outlined,
        'faculty' => Icons.person_search_outlined,
        'energy' => Icons.bolt_outlined,
        'climate' => Icons.ac_unit,
        _ => Icons.widgets_outlined,
      },
      defaultSize: _cardDefaults[type ?? id] ?? HomeCardSize.regular,
    );
    return [
      if (data.schedule != null)
        entry(
          'schedule',
          l10n.homeScheduleTitle,
          (_) => ScheduleCard(data.schedule!),
        )
      else if (_liveSections && data.supportsAll(const ['schedule.week']))
        entry(
          'schedule',
          l10n.homeScheduleTitle,
          (_) => ScheduleSection(
            calendarEnabled: data.supportsAll(const ['calendar.academic']),
          ),
        ),
      if (data.grades != null)
        entry(
          'grades',
          l10n.homeGradesTitle,
          (_) => GradesCard(data.grades!, summary: data.gpaSummary),
        )
      else if (_liveSections && data.supportsAll(const ['grades.list']))
        entry('grades', l10n.homeGradesTitle, (_) => const GradesSection()),
      if (data.notices != null)
        entry('notice', l10n.homeNoticeTitle, (_) => NoticeCard(data.notices!))
      else if (_liveSections && data.supportsAll(const ['notice.list']))
        entry(
          'notice',
          l10n.homeNoticeTitle,
          (_) => SectionCard(
            title: l10n.homeNoticeTitle,
            child: Text(l10n.homeNoticeUnavailable),
          ),
        ),
      for (final section in data.genericSections)
        entry(
          'generic:${section.sectionId}',
          section.title,
          (_) => GenericSectionCard(section),
          type: 'generic',
        ),
      if (_liveSections &&
          const [
            'card.balance',
            'card.transactions',
            'card.qr',
          ].any(data.supportedCapabilities.contains))
        entry(
          'card',
          l10n.homeCardTitle,
          (_) => CardSection(
            balanceEnabled: data.supportsAll(const ['card.balance']),
            qrEnabled: data.supportsAll(const ['card.qr']),
            transactionsEnabled: data.supportsAll(const ['card.transactions']),
          ),
        ),
      if (_liveSections && data.supportsAll(const ['exam.list']))
        entry('exam', l10n.homeExamTitle, (_) => const ExamSection()),
      if (_liveSections && data.supportsAll(const ['faculty.search']))
        entry(
          'faculty',
          l10n.facultyTitle,
          (_) => const FacultySearchSection(),
        ),
      if (_liveSections && data.supportsAll(const ['library.loans']))
        entry(
          'library',
          l10n.homeLibraryLoansTitle,
          (_) => const LibraryLoansSection(),
        ),
      if (_liveSections &&
          data.supportsAll(const ['energy.meters', 'energy.usage']))
        entry('energy', l10n.energyTitle, (_) => const EnergySection()),
      if (_liveSections &&
          data.supportsAll(const ['climate.devices', 'climate.status']))
        entry('climate', l10n.climateTitle, (_) => const ClimateSection()),
      if (_liveSections &&
          data.supportsAll(const [
            'classroom.buildings',
            'classroom.available',
          ]))
        entry(
          'classroom',
          l10n.homeClassroomTitle,
          (_) => const ClassroomSection(),
        ),
    ];
  }

  /// 是否装配按需取数区：仅真数据模式（无注入、无 demo）——否则无 [SessionScope]。
  bool get _liveSections =>
      widget.loadSnapshot == null && !(kDebugMode && kForceDemoHomeSnapshot);

  Future<CampusSnapshot> _load() {
    if (widget.loadSnapshot != null) return widget.loadSnapshot!();
    if (kDebugMode && kForceDemoHomeSnapshot) {
      return loadDemoCampusSnapshot();
    }
    return loadCampusSnapshot(SessionScope.of(context), preferCacheOnly: true);
  }

  Future<void> _reload() async {
    if (_liveSections) {
      await _refreshSilently(force: true);
      if (!mounted) return;
    }
    final next = Future<CampusSnapshot>.sync(_load);
    setState(() {
      _snapshot = next;
    });

    // A pull-to-refresh already in flight also waits for a newer icon-triggered
    // refresh, so its spinner cannot finish while the latest generation runs.
    var observed = next;
    while (true) {
      try {
        await observed;
      } on Object {
        // FutureBuilder owns rendering the latest error state.
      }
      if (identical(observed, _snapshot)) return;
      observed = _snapshot;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: FutureBuilder<CampusSnapshot>(
          key: ValueKey((_school, _generation)),
          future: _snapshot,
          builder: (context, state) {
            if (state.hasData) _lastSnapshot = state.data;
            final data = state.data ?? _lastSnapshot;
            if (state.connectionState != ConnectionState.done && data == null) {
              return const _LoadingState();
            }
            if (state.hasError && data == null) {
              return _ErrorState(
                error: state.error.toString(),
                onRetry: _reload,
              );
            }
            if (data == null) {
              return _EmptyState(onRetry: _reload);
            }
            return RefreshIndicator(
              onRefresh: _reload,
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 24, 8, 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: _SnapshotHeader(snapshot: data)),
                          IconButton(
                            tooltip: AppLocalizations.of(context).homeRefresh,
                            onPressed: _reload,
                            icon: const Icon(Icons.refresh),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      0,
                      16,
                      liquidGlassEnabled(context) ? 100 : 24,
                    ),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (data.isEmpty) _EmptyState(onRetry: _reload),
                          EditableCardBoard(
                            scopeId: _school ?? 'preview',
                            store: widget.layoutStore,
                            cards: _cards(data),
                          ),
                        ],
                      ),
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
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          snapshot.homeTitle ?? snapshot.schoolName,
          key: const ValueKey('home-title'),
          style: theme.textTheme.headlineMedium,
        ),
        const SizedBox(height: 6),
        Text(
          snapshot.updatedAt == null
              ? l10n.homeDataNotUpdated
              : l10n.homeDataUpdatedAt(
                  formatLocalDateTime(snapshot.updatedAt!),
                ),
          key: const ValueKey('home-updated-at'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class GradesCard extends StatelessWidget {
  const GradesCard(this.data, {this.summary, super.key});

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
      child: CardPreviewList(
        title: '成绩',
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
    final l10n = AppLocalizations.of(context);
    return SectionCard(
      title: l10n.homeNoticeTitle,
      subtitle: l10n.homeNoticeCount(data.items.length),
      summary: CardSummary(
        data.items.firstOrNull?.title ?? l10n.homeNoticeCount(0),
        detail: data.items.isEmpty
            ? null
            : [
                data.items.first.source,
                if (data.items.first.publishedAtDateTime != null)
                  formatLocalDate(data.items.first.publishedAtDateTime!),
              ].where((s) => s.trim().isNotEmpty).join(' · '),
      ),
      child: CardPreviewList(
        title: l10n.homeNoticeTitle,
        children: [
          for (final item in data.items)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(item.title),
              subtitle: Text(
                [
                      item.source,
                      _noticeCategoryText(l10n, item.category),
                      // 契约 publishedAt 为 RFC3339 字符串；经视图扩展转 DateTime 展示。
                      if (item.publishedAtDateTime != null)
                        formatLocalDate(item.publishedAtDateTime!),
                      if (item.summary != null) item.summary!,
                    ]
                    .map((value) => value.trim())
                    .where((value) => value.isNotEmpty)
                    .join(' · '),
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

class GenericSectionCard extends StatelessWidget {
  const GenericSectionCard(this.section, {super.key});

  final GenericSection section;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: section.title,
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
    return formatLocalDateTime(value);
  }
  return value.toString();
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
