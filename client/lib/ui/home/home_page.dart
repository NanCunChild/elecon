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
import 'capability_source.dart';
import 'generic_section.dart';
import 'card_layout_store.dart';
import 'editable_card_board.dart';
import 'capability_sections.dart';
import 'demo_data.dart';
import 'display_date.dart';
import 'desktop_placeholder.dart';
import 'models.dart';
import 'result_cards.dart';
export 'result_cards.dart';
import 'section_card.dart';
import 'schedule_view.dart';
export 'schedule_view.dart' show ScheduleCard;
import 'energy_climate_sections.dart';
import 'faculty_search_section.dart';
import 'checkin_section.dart';
import 'web_content_section.dart';
import '../widgets/adaptive_school_title.dart';

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
  var _refreshAfterDesktop = false;
  SessionController? _session;
  String? _school;
  int? _revision;
  int? _generation;
  int? _dataGeneration;
  CampusSnapshot? _lastSnapshot;
  Timer? _homeRefreshTimer;
  Map<String, HomeCardSize> _cardDefaults = {};
  Set<String> _explicitDefaultTypes = {};
  CapabilitySource? _noticeSource;
  bool _noticeSourceResolved = false;
  List<(ScriptPackage, ScriptCardEntry)> _scriptCards = const [];
  List<(ScriptPackage, ScriptWebContent)> _webPages = const [];

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
      setState(() {});
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
      if (mounted) {
        // Refresh relative timestamps even when data stays cached.
        setState(() {});
        unawaited(_refreshSilently());
      }
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
          _generation != session.trustedScriptViewGeneration ||
          _dataGeneration != session.trustedScriptDataGeneration;
      if (changed) {
        _session = session;
        _school = session.selectedSchool?.id;
        _generation = session.trustedScriptViewGeneration;
        _dataGeneration = session.trustedScriptDataGeneration;
        _lastSnapshot = null;
        _refreshAfterDesktop = true;
        _cardDefaults = {};
        _explicitDefaultTypes = {};
        _noticeSource = null;
        _noticeSourceResolved = false;
        _scriptCards = const [];
        _webPages = const [];
        unawaited(_loadCardDefaults(session));
      }
      if (!_bound || changed || _revision != session.homeDataRevision) {
        _revision = session.homeDataRevision;
        _bound = true;
        _snapshot = _load();
      }
      if (changed) {
        _scheduleHomeRefresh();
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
      final noticeProvider = registry.provider(school, 'notice.list');
      final noticeSource = noticeProvider == null
          ? null
          : CapabilitySource(
              packageId: noticeProvider.manifest.id,
              digest: noticeProvider.digest,
            );
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
      final explicitDefaults = <String>{};
      for (final entry in ScriptCardEntry.requiredCapabilitiesByType.entries) {
        final selected = registry.provider(school, entry.value.first);
        final declarations =
            selected?.manifest.cards
                .where((card) => card.type == entry.key)
                .toList() ??
            [];
        if (declarations.isNotEmpty &&
            declarations.every((card) => card.hasExplicitId)) {
          explicitDefaults.add(entry.key);
        }
      }
      final instances = <(ScriptPackage, ScriptCardEntry)>[];
      final webPages = <(ScriptPackage, ScriptWebContent)>[];
      for (final installation in registry.installations) {
        final package = installation.package;
        if (!installation.enabled ||
            package.requiresUpdate ||
            package.manifest.schoolId != school) {
          continue;
        }
        for (final page in package.manifest.webContent) {
          webPages.add((package, page));
        }
        for (final card in package.manifest.cards.where(
          (c) => c.hasExplicitId,
        )) {
          instances.add((package, card));
          defaults['script:${package.manifest.id}/${card.id}'] = HomeCardSize
              .values
              .byName(card.defaultVariant);
        }
      }
      if (mounted &&
          identical(session, _session) &&
          school == _school &&
          generation == _generation) {
        setState(() {
          _noticeSource = noticeSource;
          _noticeSourceResolved = true;
          _cardDefaults = defaults;
          _scriptCards = instances;
          _webPages = webPages;
          _explicitDefaultTypes = explicitDefaults;
        });
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
        'checkin' => Icons.qr_code_scanner,
        'web' => Icons.web_outlined,
        _ => Icons.widgets_outlined,
      },
      defaultSize:
          _cardDefaults[id] ??
          _cardDefaults[type ?? id] ??
          HomeCardSize.regular,
    );
    final cards = <HomeCardEntry>[
      if (data.schedule != null)
        entry(
          'schedule',
          l10n.homeScheduleTitle,
          (_) => ScheduleCard(
            data.schedule!,
            trailing: SectionRefreshButton(onPressed: _reload),
          ),
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
          (_) => GradesCard(
            data.grades!,
            summary: data.gpaSummary,
            trailing: SectionRefreshButton(onPressed: _reload),
          ),
        )
      else if (_liveSections && data.supportsAll(const ['grades.list']))
        entry('grades', l10n.homeGradesTitle, (_) => const GradesSection()),
      if (_liveSections &&
          _noticeSourceResolved &&
          data.supportsAll(const ['notice.list']))
        entry('notice', l10n.homeNoticeTitle, (_) {
          final section = NoticeSection(
            initialData: data.notices,
            generation: _generation,
          );
          return _noticeSource == null
              ? section
              : CapabilitySourceScope(source: _noticeSource!, child: section);
        })
      else if (!_liveSections && data.notices != null)
        entry(
          'notice',
          l10n.homeNoticeTitle,
          (_) => NoticeCard(
            data.notices!,
            trailing: SectionRefreshButton(onPressed: _reload),
          ),
        ),
      for (final section in data.genericSections)
        entry(
          'generic:${section.sectionId}',
          section.title,
          (_) => GenericSectionCard(
            section,
            trailing: SectionRefreshButton(onPressed: _reload),
          ),
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
      if (_liveSections && data.supportsAll(const ['attendance.checkin']))
        entry('checkin', l10n.homeCheckinTitle, (_) => const CheckinSection()),
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
    cards.removeWhere((card) => _explicitDefaultTypes.contains(card.id));
    for (final (package, declaration) in _scriptCards) {
      Widget feature() => switch (declaration.type) {
        'notice' => const NoticeSection(),
        'schedule' => ScheduleSection(
          calendarEnabled:
              package.manifest.capability('calendar.academic') != null,
        ),
        'grades' => const GradesSection(),
        'library' => const LibraryLoansSection(),
        'exam' => const ExamSection(),
        'classroom' => const ClassroomSection(),
        'energy' => const EnergySection(),
        'climate' => const ClimateSection(),
        'card' => CardSection(
          balanceEnabled: package.manifest.capability('card.balance') != null,
          qrEnabled: package.manifest.capability('card.qr') != null,
          transactionsEnabled:
              package.manifest.capability('card.transactions') != null,
        ),
        'generic' => const GenericCapabilitySection(),
        _ => const SizedBox.shrink(),
      };
      final label =
          declaration.title ??
          switch (declaration.type) {
            'notice' => l10n.homeNoticeTitle,
            'schedule' => l10n.homeScheduleTitle,
            'grades' => l10n.homeGradesTitle,
            'library' => l10n.homeLibraryLoansTitle,
            'exam' => l10n.homeExamTitle,
            'classroom' => l10n.homeClassroomTitle,
            'energy' => l10n.energyTitle,
            'climate' => l10n.climateTitle,
            'card' => l10n.homeCardTitle,
            _ => package.manifest.name,
          };
      cards.add(
        entry(
          'script:${package.manifest.id}/${declaration.id}',
          label,
          (_) => CapabilitySourceScope(
            source: CapabilitySource(
              packageId: package.manifest.id,
              digest: package.digest,
            ),
            title: label,
            child: feature(),
          ),
          type: declaration.type,
        ),
      );
    }
    for (final (package, page) in _webPages) {
      cards.add(
        entry(
          'web:${package.manifest.id}/${page.id}',
          page.title,
          (_) => WebContentSection(
            session: _session!,
            package: package,
            page: page,
          ),
          type: 'web',
        ),
      );
    }
    return cards;
  }

  /// 是否装配按需取数区：仅真数据模式（无注入、无 demo）——否则无 [SessionScope]。
  bool get _liveSections =>
      widget.loadSnapshot == null && !(kDebugMode && kForceDemoHomeSnapshot);

  Future<CampusSnapshot> _load({bool refreshNotices = false}) async {
    if (widget.loadSnapshot != null) return widget.loadSnapshot!();
    if (kDebugMode && kForceDemoHomeSnapshot) {
      return loadDemoCampusSnapshot();
    }
    final session = SessionScope.of(context);
    final dataGeneration = session.trustedScriptDataGeneration;
    final snapshot = await loadCampusSnapshot(
      session,
      preferCacheOnly: !refreshNotices,
      refreshNotices: refreshNotices,
    );
    await (widget.layoutStore ?? CardLayoutStore.shared).load(
      session.selectedSchool?.id ?? 'preview',
    );
    if (dataGeneration != session.trustedScriptDataGeneration) {
      throw StateError('identity_changed');
    }
    return snapshot;
  }

  Future<void> _reload() async {
    var refreshNotices = false;
    if (_liveSections) {
      final session = _session;
      final generation = _generation;
      final dataGeneration = _dataGeneration;
      final school = _school;
      bool current() =>
          mounted &&
          identical(session, _session) &&
          session?.trustedScriptViewGeneration == generation &&
          session?.trustedScriptDataGeneration == dataGeneration &&
          session?.selectedSchool?.id == school;
      await _refreshSilently(force: true);
      if (!current()) return;
      if (_lastSnapshot?.supportedCapabilities.contains('notice.list') ??
          false) {
        final provider = (await session!.scriptRegistry).provider(
          school!,
          'notice.list',
        );
        refreshNotices =
            !(provider?.manifest.home.any(
                  (entry) => entry.capability == 'notice.list' && entry.preload,
                ) ??
                false);
        if (!current()) return;
      }
    }
    final next = Future<CampusSnapshot>.sync(
      () => _load(refreshNotices: refreshNotices),
    );
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
          key: ValueKey((_school, _generation, _dataGeneration)),
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
            if (_liveSections && _refreshAfterDesktop) {
              _refreshAfterDesktop = false;
              final session = _session;
              final generation = _generation;
              final dataGeneration = _dataGeneration;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted &&
                    identical(session, _session) &&
                    generation == _generation &&
                    dataGeneration == _dataGeneration) {
                  unawaited(_refreshSilently());
                }
              });
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
        AdaptiveSchoolTitle(
          text: snapshot.homeTitle ?? snapshot.schoolName,
          key: const ValueKey('home-title'),
          style: theme.textTheme.headlineMedium,
        ),
        if (snapshot.schoolType case final type?) ...[
          const SizedBox(height: 4),
          Text(
            type,
            key: const ValueKey('home-school-type'),
            style: theme.textTheme.titleMedium,
          ),
        ],
        const SizedBox(height: 6),
        Text(
          snapshot.updatedAt == null
              ? l10n.homeDataNotUpdated
              : l10n.homeDataUpdatedAt(
                  formatUpdateTime(snapshot.updatedAt!, l10n),
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

class _LoadingState extends StatelessWidget {
  const _LoadingState();
  @override
  Widget build(BuildContext context) => const DesktopPlaceholder();
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
