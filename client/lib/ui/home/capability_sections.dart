/// 首页「按需取数」能力区：成绩 / 课表 / 空教室 / 一卡通 / 考试 / 图书借阅。
///
/// 各能力所需凭证由 manifest 声明，[SessionController.runCapability] 内部按需确保。
/// ADR-038 声明的缓存可立即恢复，后台刷新不弹交互；UI 不接触凭证值（红线 #1）。
/// 手动取数的 auth 失败复用 [runSchoolLogin]，成功后重试能力。
///
/// 卡片由标准 schema 选择并在客户端固定实现，不接受 adapter 渲染描述（ADR-004 §2.1）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/adapter_service.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import '../../session/session_scope.dart';
import '../login/login_flow.dart';
import '../login/webview_login_page.dart';
import 'display_date.dart';
import 'card_layout.dart';
import 'card_preview_list.dart';
import 'home_page.dart' show GradesCard, ScheduleCard;
import 'models.dart';
import 'schema_decode.dart';
import 'section_card.dart';

/// 一次能力取数 + 解码的归一化结果。
class _Outcome<T> {
  const _Outcome({this.data, this.needLogin = false, this.error, this.reason});

  final T? data;
  final bool needLogin;
  final String? error;
  final String? reason;
}

/// 跑能力 → 解码。auth 失败归为 [needLogin]（引导可见登录后重试），不外泄凭证/原因语义。
Future<_Outcome<T>> _runOnceDecoded<T>(
  SessionController session,
  String capability, {
  Map<String, dynamic>? params,
  required T? Function(Object?) decode,
}) async {
  final run = await session.runCapability(capability, params: params);
  if (!run.ok) {
    if (run.failureKind == CapabilityFailureKind.auth ||
        run.reason == 'authentication_required') {
      return const _Outcome(needLogin: true);
    }
    final reason = run.reason?.trim();
    final kind = run.failureKind?.name ?? 'unknown';
    return _Outcome(
      reason: reason,
      error: reason == null || reason.isEmpty
          ? '$capability 失败（$kind）'
          : '$capability 失败（$kind）：$reason',
    );
  }
  final data = decode(run.data);
  if (data == null) return _Outcome(error: '$capability 产出无法解码');
  return _Outcome(data: data);
}

Future<_Outcome<T>> _runDecoded<T>(
  BuildContext context,
  SessionController session,
  String capability, {
  Map<String, dynamic>? params,
  required T? Function(Object?) decode,
}) async {
  final first = await _runOnceDecoded(
    session,
    capability,
    params: params,
    decode: decode,
  );
  if (context.mounted) {
    final l10n = AppLocalizations.of(context);
    final message = switch (first.reason) {
      'network_denied' => l10n.scriptsNetworkDenied,
      'source_response_invalid' => l10n.scriptsSourceResponseInvalid,
      'authentication_timeout' => l10n.scriptsAuthenticationTimeout,
      'input_cancelled' => l10n.scriptsInputCancelled,
      _ => null,
    };
    if (message != null) return _Outcome(error: message);
  }
  return first;
}

/// 引导当前会话学校的可见登录；成功返回 true。凭证收割在核心（红线 #1）。
Future<bool> _promptVisibleLogin(
  BuildContext context,
  SessionController session, {
  String? targetRef,
}) async {
  final school = session.selectedSchool;
  if (school == null) return false;
  final serviceUrl = targetRef == null
      ? null
      : school.login.ssoMint?.services[targetRef]?.service;
  final result = await runSchoolLogin(
    context,
    session,
    school,
    initialUrl: serviceUrl,
    requiredRef: targetRef,
  );
  return result?.status == WebViewLoginStatus.success;
}

// ADR-038: even an earlier successful stage becomes unusable after session
// replacement, logout or an approved-package change during a later await.
bool _isCurrentSession(
  State state,
  SessionController session,
  int generation,
) =>
    state.mounted &&
    identical(SessionScope.of(state.context), session) &&
    session.trustedScriptViewGeneration == generation;

enum _Phase { idle, loading, loaded, needLogin, error }

/// ADR-038: restore validated current-school data independently of widget life.
/// Background writes notify SessionScope; failed refreshes never replace data.
mixin _CachedSection<W extends StatefulWidget, D> on State<W> {
  SessionController? _cacheSession;
  String? _cacheSchool;
  int? _cacheRevision;
  int? _cacheGeneration;
  int _cacheRead = 0;
  DateTime? _cacheFetchedAt;
  bool _cacheStale = false;
  Map<String, dynamic> _restoredParams = const {};

  String get cacheCapability;
  D? decodeCache(Object? value);
  Map<String, dynamic>? get cacheParams => null;
  bool get useLatestCache => cacheParams == null;
  void applyCache(D data);
  void clearCache();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = SessionScope.of(context);
    final school = session.selectedSchool?.id;
    final changed =
        _cacheSession != session ||
        _cacheSchool != school ||
        _cacheGeneration != session.trustedScriptViewGeneration;
    if (changed) {
      _cacheSession = session;
      _cacheSchool = school;
      _cacheGeneration = session.trustedScriptViewGeneration;
      _cacheRead++;
      _cacheFetchedAt = null;
      clearCache();
    }
    if (changed || _cacheRevision != session.homeDataRevision) {
      _cacheRevision = session.homeDataRevision;
      unawaited(restoreCache());
    }
  }

  Future<void> restoreCache() async {
    final session = _cacheSession;
    if (session == null) return;
    final read = ++_cacheRead;
    final generation = session.trustedScriptViewGeneration;
    final school = _cacheSchool;
    try {
      final cached = useLatestCache
          ? await session.latestCachedCapability(cacheCapability)
          : await session.cachedCapability(
              cacheCapability,
              params: cacheParams,
            );
      if (!_isCurrentSession(this, session, generation) ||
          read != _cacheRead ||
          session.selectedSchool?.id != school) {
        return;
      }
      final decoded = cached == null ? null : decodeCache(cached.data);
      if (decoded == null) {
        // Revoked, disabled or updated packages cannot leave old cached values
        // visible. A fresh manual result without a cache remains usable.
        if (_cacheFetchedAt != null) {
          setState(() {
            _cacheFetchedAt = null;
            clearCache();
          });
        }
        return;
      }
      setState(() {
        _restoredParams = cached!.params;
        _cacheFetchedAt = cached.fetchedAt;
        _cacheStale = cached.isStale;
        applyCache(decoded);
      });
    } catch (_) {
      // Cache read failure must not erase a successful visible result.
    }
  }

  Widget withCacheTime(Widget child) {
    final presentation = HomeCardPresentation.maybeOf(context);
    final height = presentation?.previewHeight;
    final caption = _cacheFetchedAt == null
        ? null
        : (_cacheStale
              ? AppLocalizations.of(context).homeDataStaleAt(
                  _formatTimestamp(_cacheFetchedAt!.toIso8601String()),
                )
              : AppLocalizations.of(context).homeDataUpdatedAt(
                  _formatTimestamp(_cacheFetchedAt!.toIso8601String()),
                ));
    final style = Theme.of(context).textTheme.bodySmall!;
    final footerHeight = caption == null
        ? 0.0
        : MediaQuery.textScalerOf(context).scale(style.fontSize!) *
                  (style.height ?? 1.4) *
                  2 +
              8;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (height != null)
          HomeCardPresentation(
            size: presentation!.size,
            preset: presentation.preset,
            icon: presentation.icon,
            onOpen: presentation.onOpen,
            previewHeight: height - footerHeight,
            child: child,
          )
        else
          child,
        if (caption != null)
          SizedBox(
            height: height == null ? null : footerHeight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(
                caption,
                maxLines: height == null ? null : 2,
                overflow: height == null ? null : TextOverflow.ellipsis,
                style: style.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ===========================================================================
// 成绩（无参）
// ===========================================================================

class GradesSection extends StatefulWidget {
  const GradesSection({super.key});

  @override
  State<GradesSection> createState() => _GradesSectionState();
}

class _GradesSectionState extends State<GradesSection>
    with _CachedSection<GradesSection, GradesList> {
  @override
  String get cacheCapability => 'grades.list';
  @override
  GradesList? decodeCache(Object? value) => gradesListFromDynamic(value);
  @override
  void applyCache(GradesList data) {
    _data = data;
    _phase = _Phase.loaded;
  }

  @override
  void clearCache() {
    _data = null;
    _phase = _Phase.idle;
    _summary = null;
  }

  _Phase _phase = _Phase.idle;
  GradesList? _data;
  GpaSummary? _summary;
  String? _error;

  Future<void> _load() async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    setState(() => _phase = _Phase.loading);
    final outcome = await _runDecoded<GradesList>(
      context,
      session,
      'grades.list',
      decode: gradesListFromDynamic,
    );
    if (!mounted || !_isCurrentSession(this, session, generation)) return;
    // 学校官方绩点汇总：**可选增强**，取不到不影响成绩单本身（ADR-001 §3.5——
    // 官方数存在时权威，不存在时卡片退到本机聚合并换标签）。故失败一律吞掉，
    // 不把它的 needLogin/error 冒泡成整个成绩区的失败态。
    final summary = outcome.data == null
        ? null
        : await _loadGpaSummary(session);
    if (!mounted || !_isCurrentSession(this, session, generation)) return;
    setState(() {
      if (outcome.needLogin) {
        _phase = _data == null ? _Phase.needLogin : _Phase.loaded;
      } else if (outcome.error != null) {
        _phase = _data == null ? _Phase.error : _Phase.loaded;
        _error = outcome.error;
      } else {
        _phase = _Phase.loaded;
        _data = outcome.data;
        _summary = summary;
      }
    });
  }

  @override
  Future<void> restoreCache() async {
    await super.restoreCache();
    final session = _cacheSession;
    if (session == null) return;
    final read = _cacheRead;
    final generation = session.trustedScriptViewGeneration;
    final cached = await session.cachedCapability('gpa.summary');
    if (_isCurrentSession(this, session, generation) &&
        read == _cacheRead &&
        cached != null) {
      final summary = gpaSummaryFromDynamic(cached.data);
      if (summary != null) setState(() => _summary = summary);
    }
  }

  /// 取 `gpa.summary`；任何失败都返回 null（见 [_load] 中的理由）。
  Future<GpaSummary?> _loadGpaSummary(SessionController session) async {
    try {
      final run = await _runDecoded<GpaSummary>(
        context,
        session,
        'gpa.summary',
        decode: gpaSummaryFromDynamic,
      );
      return run.data;
    } on Object {
      return null;
    }
  }

  Future<void> _login() async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final ok = await _promptVisibleLogin(context, session);
    if (!mounted || !_isCurrentSession(this, session, generation)) return;
    if (ok) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_data != null) {
      return withCacheTime(GradesCard(_data!, summary: _summary));
    }
    return _PromptCard(
      title: '成绩',
      summary: _querySummary(context, _phase),
      subtitle: '登录后查看本学期成绩单',
      child: _PhaseBody(
        phase: _phase,
        error: _error,
        idleLabel: '查看成绩',
        onLoad: _load,
        onLogin: _login,
      ),
    );
  }
}

// ===========================================================================
// 课表（需 week；提供周次选择器）
// ===========================================================================

class ScheduleSection extends StatefulWidget {
  const ScheduleSection({super.key, this.calendarEnabled = false});

  final bool calendarEnabled;

  @override
  State<ScheduleSection> createState() => _ScheduleSectionState();
}

class _ScheduleSectionState extends State<ScheduleSection>
    with _CachedSection<ScheduleSection, ScheduleWeek> {
  @override
  String get cacheCapability => 'schedule.week';
  @override
  ScheduleWeek? decodeCache(Object? value) => scheduleWeekFromDynamic(value);
  @override
  void applyCache(ScheduleWeek data) {
    _data = data;
    _phase = _Phase.loaded;
    _week = data.week;
    _term = data.term;
    _calendarLoaded = true;
  }

  @override
  void clearCache() {
    _data = null;
    _phase = _Phase.idle;
    _week = 1;
    _term = null;
    _calendarLoaded = false;
    _manualWeek = false;
  }

  @override
  bool get useLatestCache => !_manualWeek;
  @override
  Map<String, dynamic>? get cacheParams => {
    'week': _week,
    if (_term != null) 'term': _term,
  };

  int get _maxWeek => _week > 25 ? _week : 25;

  _Phase _phase = _Phase.idle;
  int _week = 1;
  bool _calendarLoaded = false;
  bool _manualWeek = false;
  String? _term;
  bool get _queryCurrentWeek => widget.calendarEnabled && !_manualWeek;
  bool get _needsCurrentWeek => _queryCurrentWeek && !_calendarLoaded;
  ScheduleWeek? _data;
  String? _error;

  Future<void> _load() async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    setState(() => _phase = _Phase.loading);
    if (_queryCurrentWeek) {
      final calendar = await _runDecoded<CalendarAcademic>(
        context,
        session,
        'calendar.academic',
        decode: calendarAcademicFromDynamic,
      );
      if (!mounted || !_isCurrentSession(this, session, generation)) return;
      if (calendar.data == null) {
        setState(() {
          _phase = calendar.needLogin ? _Phase.needLogin : _Phase.error;
          _error = calendar.error;
        });
        return;
      }
      setState(() {
        _week = calendar.data!.currentWeek ?? 1;
        _term = calendar.data!.term;
        _calendarLoaded = true;
      });
    }
    final outcome = await _runDecoded<ScheduleWeek>(
      context,
      session,
      'schedule.week',
      params: {'week': _week, if (_term != null) 'term': _term},
      decode: scheduleWeekFromDynamic,
    );
    if (!mounted || !_isCurrentSession(this, session, generation)) return;
    setState(() {
      if (outcome.needLogin) {
        _phase = _data == null ? _Phase.needLogin : _Phase.loaded;
      } else if (outcome.error != null) {
        _phase = _data == null ? _Phase.error : _Phase.loaded;
        _error = outcome.error;
      } else {
        _phase = _Phase.loaded;
        _data = outcome.data;
      }
    });
  }

  Future<void> _login() async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final ok = await _promptVisibleLogin(context, session);
    if (!mounted || !_isCurrentSession(this, session, generation)) return;
    if (ok) await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_data != null && HomeCardPresentation.isPreview(context)) {
      return withCacheTime(ScheduleCard(_data!));
    }
    final busy = _phase == _Phase.loading;
    final l10n = AppLocalizations.of(context);
    return Column(
      children: [
        _PromptCard(
          title: l10n.homeScheduleTitle,
          summary: _querySummary(context, _phase),
          subtitle: l10n.homeSchedulePrompt,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_needsCurrentWeek)
                TextButton(
                  onPressed: busy
                      ? null
                      : () => setState(() => _manualWeek = true),
                  child: Text(l10n.homeScheduleSelectWeek),
                )
              else
                _WeekPicker(
                  week: _week,
                  maxWeek: _maxWeek,
                  enabled: !busy,
                  onChanged: (w) => setState(() {
                    _week = w;
                    _manualWeek = true;
                    _data = null;
                    _cacheFetchedAt = null;
                    _phase = _Phase.idle;
                    unawaited(restoreCache());
                  }),
                ),
              const SizedBox(height: 8),
              _PhaseBody(
                phase: _phase,
                error: _error,
                idleLabel: _queryCurrentWeek
                    ? l10n.homeScheduleLoadCurrent
                    : l10n.homeScheduleLoadWeek(_week),
                loadingHidden: false,
                onLoad: _load,
                onLogin: _login,
              ),
            ],
          ),
        ),
        if (_data != null) withCacheTime(ScheduleCard(_data!)),
      ],
    );
  }
}

class _WeekPicker extends StatelessWidget {
  const _WeekPicker({
    required this.week,
    required this.maxWeek,
    required this.enabled,
    required this.onChanged,
  });

  final int week;
  final int maxWeek;
  final bool enabled;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          onPressed: enabled && week > 1 ? () => onChanged(week - 1) : null,
          icon: const Icon(Icons.remove_circle_outline),
        ),
        Text('第 $week 周', style: Theme.of(context).textTheme.titleMedium),
        IconButton(
          onPressed: enabled && week < maxWeek
              ? () => onChanged(week + 1)
              : null,
          icon: const Icon(Icons.add_circle_outline),
        ),
      ],
    );
  }
}

// ===========================================================================
// 空教室（需 building + date；先取教学楼列表，再查空闲）
// ===========================================================================

class ClassroomSection extends StatefulWidget {
  const ClassroomSection({super.key});

  @override
  State<ClassroomSection> createState() => _ClassroomSectionState();
}

class _ClassroomSectionState extends State<ClassroomSection>
    with _CachedSection<ClassroomSection, ClassroomAvailable> {
  bool _manualSelection = false;
  @override
  String get cacheCapability => 'classroom.available';
  @override
  ClassroomAvailable? decodeCache(Object? value) =>
      classroomAvailableFromDynamic(value);
  @override
  bool get useLatestCache => !_manualSelection;
  @override
  Map<String, dynamic>? get cacheParams => {
    'date': _formatDate(_date),
    if (_selected?.buildingId != null)
      'buildingId': _selected!.buildingId
    else if (_selected != null)
      'building': _selected!.building,
  };
  @override
  void applyCache(ClassroomAvailable data) {
    _avail = data;
    _availPhase = _Phase.loaded;
    _date =
        DateTime.tryParse(
          data.date ?? _restoredParams['date']?.toString() ?? '',
        ) ??
        _date;
  }

  @override
  void clearCache() {
    _buildingsPhase = _Phase.idle;
    _buildings = const [];
    _selected = null;
    _avail = null;
    _availPhase = _Phase.idle;
    _date = DateTime.now();
    _manualSelection = false;
  }

  @override
  Future<void> restoreCache() async {
    await super.restoreCache();
    final session = _cacheSession;
    if (session == null) return;
    final read = _cacheRead;
    final generation = session.trustedScriptViewGeneration;
    final cached = await session.cachedCapability('classroom.buildings');
    if (!_isCurrentSession(this, session, generation) ||
        read != _cacheRead ||
        cached == null) {
      return;
    }
    final decoded = classroomBuildingsFromDynamic(cached.data);
    if (decoded == null) return;
    setState(() {
      _buildings = decoded.items ?? const [];
      _buildingsPhase = _Phase.loaded;
      if (!_buildings.contains(_selected)) {
        final matches = _buildings.where(
          (item) =>
              item.buildingId == _restoredParams['buildingId'] &&
                  item.buildingId != null ||
              item.building == _restoredParams['building'],
        );
        _selected = matches.firstOrNull ?? _buildings.firstOrNull;
      }
    });
  }

  // 教学楼列表阶段
  _Phase _buildingsPhase = _Phase.idle;
  List<ClassroomBuildingsItems> _buildings = const [];
  String? _buildingsError;
  ClassroomBuildingsItems? _selected;

  // 空教室查询阶段
  _Phase _availPhase = _Phase.idle;
  DateTime _date = DateTime.now();
  ClassroomAvailable? _avail;
  String? _availError;

  Future<void> _loadBuildings() async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    setState(() => _buildingsPhase = _Phase.loading);
    final outcome = await _runDecoded<ClassroomBuildings>(
      context,
      session,
      'classroom.buildings',
      decode: classroomBuildingsFromDynamic,
    );
    if (!mounted || !_isCurrentSession(this, session, generation)) return;
    setState(() {
      if (outcome.needLogin) {
        _buildingsPhase = _Phase.needLogin;
      } else if (outcome.error != null) {
        _buildingsPhase = _Phase.error;
        _buildingsError = outcome.error;
      } else {
        _buildingsPhase = _Phase.loaded;
        _buildings = outcome.data?.items ?? const [];
        _selected = _buildings.isNotEmpty ? _buildings.first : null;
      }
    });
  }

  Future<void> _loginThenBuildings() async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final ok = await _promptVisibleLogin(context, session);
    if (!mounted || !_isCurrentSession(this, session, generation)) return;
    if (ok) await _loadBuildings();
  }

  Future<void> _loadAvailable() async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final building = _selected;
    if (building == null) return;
    setState(() => _availPhase = _Phase.loading);
    final params = <String, dynamic>{'date': _formatDate(_date)};
    if (building.buildingId != null && building.buildingId!.isNotEmpty) {
      params['buildingId'] = building.buildingId;
    } else {
      params['building'] = building.building;
    }
    final outcome = await _runDecoded<ClassroomAvailable>(
      context,
      session,
      'classroom.available',
      params: params,
      decode: classroomAvailableFromDynamic,
    );
    if (!mounted || !_isCurrentSession(this, session, generation)) return;
    setState(() {
      if (outcome.needLogin) {
        _availPhase = _Phase.needLogin;
      } else if (outcome.error != null) {
        _availPhase = _Phase.error;
        _availError = outcome.error;
      } else {
        _availPhase = _Phase.loaded;
        _avail = outcome.data;
      }
    });
  }

  Future<void> _pickDate() async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: now.subtract(const Duration(days: 30)),
      lastDate: now.add(const Duration(days: 180)),
    );
    if (picked != null && _isCurrentSession(this, session, generation)) {
      setState(() {
        _date = picked;
        _manualSelection = true;
        _avail = null;
        _cacheFetchedAt = null;
        _availPhase = _Phase.idle;
      });
      unawaited(restoreCache());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (HomeCardPresentation.isPreview(context) && _avail != null) {
      return withCacheTime(_ClassroomResultCard(data: _avail!));
    }
    // 教学楼未就绪：先引导取列表（可能触发登录）。
    if (_buildingsPhase != _Phase.loaded) {
      return Column(
        children: [
          _PromptCard(
            title: '空教室',
            summary: _querySummary(context, _buildingsPhase),
            subtitle: '先加载教学楼列表',
            child: _PhaseBody(
              phase: _buildingsPhase,
              error: _buildingsError,
              idleLabel: '加载教学楼',
              onLoad: _loadBuildings,
              onLogin: _loginThenBuildings,
            ),
          ),
          if (_avail != null)
            withCacheTime(_ClassroomResultCard(data: _avail!)),
        ],
      );
    }

    final busy = _availPhase == _Phase.loading;
    return Column(
      children: [
        _PromptCard(
          title: '空教室',
          summary: _querySummary(context, _availPhase),
          subtitle: '选择教学楼与日期后查询',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButton<ClassroomBuildingsItems>(
                isExpanded: true,
                value: _selected,
                onChanged: busy
                    ? null
                    : (b) => setState(() {
                        _selected = b;
                        _manualSelection = true;
                        _avail = null;
                        _cacheFetchedAt = null;
                        _availPhase = _Phase.idle;
                        unawaited(restoreCache());
                      }),
                items: [
                  for (final b in _buildings)
                    DropdownMenuItem(
                      value: b,
                      child: Text(
                        b.roomCount == null
                            ? b.building
                            : '${b.building}（${b.roomCount} 间）',
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(child: Text('日期：${_formatDate(_date)}')),
                  TextButton.icon(
                    onPressed: busy ? null : _pickDate,
                    icon: const Icon(Icons.calendar_today, size: 18),
                    label: const Text('选择日期'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _PhaseBody(
                phase: _availPhase,
                error: _availError,
                idleLabel: '查询空教室',
                onLoad: _loadAvailable,
                onLogin: () async {
                  final session = SessionScope.of(context);
                  final generation = session.trustedScriptViewGeneration;
                  final ok = await _promptVisibleLogin(context, session);
                  if (_isCurrentSession(this, session, generation) && ok) {
                    await _loadAvailable();
                  }
                },
              ),
            ],
          ),
        ),
        if (_avail != null) withCacheTime(_ClassroomResultCard(data: _avail!)),
      ],
    );
  }
}

class _ClassroomResultCard extends StatelessWidget {
  const _ClassroomResultCard({required this.data});

  final ClassroomAvailable data;

  @override
  Widget build(BuildContext context) {
    final items = data.items ?? const [];
    final free = items
        .where(
          (i) =>
              i.occupied == false ||
              (i.occupied == null && i.status == 'available'),
        )
        .toList();
    return SectionCard(
      title: '空教室',
      summary: CardSummary(
        '${free.length}/${items.length}',
        detail: [
          AppLocalizations.of(context).homeCardAvailableRooms,
          if (data.date != null) data.date!,
        ].join(' · '),
      ),
      subtitle: [
        if (data.date != null) data.date!,
        '${free.length}/${items.length} 空闲',
      ].join(' · '),
      child: items.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('该教学楼当日无可展示教室'),
            )
          : Column(
              children: [
                for (final room in items)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      room.occupied == true
                          ? Icons.meeting_room
                          : Icons.meeting_room_outlined,
                      color: room.occupied == true
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.primary,
                    ),
                    title: Text('${room.building} ${room.room}'),
                    subtitle: Text(
                      [
                        if (room.floor != null) '${room.floor} 层',
                        if (room.capacity != null) '${room.capacity} 座',
                        if (room.status != null) _roomStatusText(room.status!),
                      ].join(' · '),
                    ),
                  ),
              ],
            ),
    );
  }
}

String _roomStatusText(String status) => switch (status) {
  'available' => '空闲',
  'occupied' => '占用',
  'partial' => '部分占用',
  _ => status,
};

// ===========================================================================
// 一卡通（用户按需；余额 → 交易明细）
// ===========================================================================

class CardSection extends StatefulWidget {
  const CardSection({super.key, this.transactionsEnabled = true});

  final bool transactionsEnabled;

  @override
  State<CardSection> createState() => _CardSectionState();
}

class _CardSectionState extends State<CardSection>
    with _CachedSection<CardSection, CardBalance> {
  @override
  String get cacheCapability => 'card.balance';
  @override
  CardBalance? decodeCache(Object? value) => cardBalanceFromDynamic(value);
  @override
  void applyCache(CardBalance data) {
    _data = data;
    _phase = _Phase.loaded;
  }

  @override
  void clearCache() {
    _data = null;
    _phase = _Phase.idle;
  }

  _Phase _phase = _Phase.idle;
  CardBalance? _data;
  String? _error;

  Future<void> _load() async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    setState(() => _phase = _Phase.loading);
    final outcome = await _runDecoded<CardBalance>(
      context,
      session,
      'card.balance',
      decode: cardBalanceFromDynamic,
    );
    if (!mounted || !_isCurrentSession(this, session, generation)) return;
    setState(() {
      if (outcome.needLogin) {
        _phase = _data == null ? _Phase.needLogin : _Phase.loaded;
      } else if (outcome.error != null) {
        _phase = _data == null ? _Phase.error : _Phase.loaded;
        _error = outcome.error;
      } else {
        _phase = _Phase.loaded;
        _data = outcome.data;
      }
    });
  }

  Future<void> _login() async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final ok = await _promptVisibleLogin(
      context,
      session,
      targetRef: 'card-session',
    );
    if (!mounted || !_isCurrentSession(this, session, generation)) return;
    if (ok) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (data == null) {
      return _PromptCard(
        title: '一卡通',
        summary: _querySummary(context, _phase),
        subtitle: widget.transactionsEnabled ? '仅在你点击后查询余额和交易记录' : '仅在你点击后查询余额',
        child: _PhaseBody(
          phase: _phase,
          error: _error,
          idleLabel: '查看余额',
          onLoad: _load,
          onLogin: _login,
        ),
      );
    }

    return withCacheTime(
      SectionCard(
        title: '一卡通',
        summary: CardSummary(
          data.errorStatus == null
              ? _money(data.balance.amountMinor, data.balance.currency)
              : _balanceErrorText(data.errorStatus!),
          detail: data.status == null ? null : _cardStatusText(data.status!),
        ),
        // 即使 adapter 错把完整卡号填进 cardNumberMasked，UI 也只从权威 cardNumber 派生末四位。
        subtitle: data.cardNumber == null
            ? AppLocalizations.of(context).cardAccountLabel
            : _maskCardNumber(data.cardNumber!),
        child: data.errorStatus == null
            ? Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _money(
                            data.balance.amountMinor,
                            data.balance.currency,
                          ),
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        if (data.status != null)
                          Text(
                            _cardStatusText(data.status!),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                  if (widget.transactionsEnabled)
                    FilledButton.tonalIcon(
                      onPressed: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => const CardTransactionsPage(),
                        ),
                      ),
                      icon: const Icon(Icons.receipt_long_outlined),
                      label: const Text('交易明细'),
                    ),
                ],
              )
            : Row(
                children: [
                  Expanded(child: Text(_balanceErrorText(data.errorStatus!))),
                  OutlinedButton.icon(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重新查询'),
                  ),
                ],
              ),
      ),
    );
  }
}

class CardTransactionsPage extends StatefulWidget {
  const CardTransactionsPage({super.key});

  @override
  State<CardTransactionsPage> createState() => _CardTransactionsPageState();
}

class _CardTransactionsPageState extends State<CardTransactionsPage> {
  _Phase _phase = _Phase.loading;
  CardTransactions? _data;
  String? _error;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _load();
    }
  }

  Future<void> _load() async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final outcome = await _runDecoded<CardTransactions>(
      context,
      session,
      'card.transactions',
      params: const {'page': 1, 'size': 20},
      decode: cardTransactionsFromDynamic,
    );
    if (!mounted || !_isCurrentSession(this, session, generation)) return;
    setState(() {
      if (outcome.needLogin) {
        _phase = _data == null ? _Phase.needLogin : _Phase.loaded;
      } else if (outcome.error != null) {
        _phase = _data == null ? _Phase.error : _Phase.loaded;
        _error = outcome.error;
      } else {
        _phase = _Phase.loaded;
        _data = outcome.data;
      }
    });
  }

  Future<void> _login() async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final ok = await _promptVisibleLogin(
      context,
      session,
      targetRef: 'card-session',
    );
    if (!mounted || !_isCurrentSession(this, session, generation)) return;
    if (ok) {
      setState(() => _phase = _Phase.loading);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('一卡通交易明细')),
      body: switch (_phase) {
        _Phase.loading => const Center(child: CircularProgressIndicator()),
        _Phase.needLogin => Center(
          child: FilledButton.icon(
            onPressed: _login,
            icon: const Icon(Icons.login),
            label: const Text('登录并查看'),
          ),
        ),
        _Phase.error => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_error ?? '加载失败', textAlign: TextAlign.center),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () {
                    setState(() => _phase = _Phase.loading);
                    _load();
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
        _Phase.idle || _Phase.loaded => _transactionsBody(context),
      },
    );
  }

  Widget _transactionsBody(BuildContext context) {
    final data = _data;
    if (data == null || data.items.isEmpty) {
      return const Center(child: Text('暂无交易记录'));
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: data.items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final item = data.items[index];
        final sign = _directionSign(item.direction);
        final color = sign == '+'
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.onSurface;
        return ListTile(
          leading: Icon(
            sign == '+'
                ? Icons.south_west
                : sign == '-'
                ? Icons.north_east
                : Icons.swap_horiz,
            color: color,
          ),
          title: Text(item.merchant ?? item.type ?? '一卡通交易'),
          subtitle: Text(
            [
              _formatTimestamp(item.time),
              if (item.location != null) item.location!,
              if (item.status != null) _transactionStatusText(item.status!),
            ].join(' · '),
          ),
          trailing: Text(
            '$sign${_money(item.amountMinor, item.currency)}',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
      },
    );
  }
}

String _directionSign(String direction) => switch (direction) {
  'credit' || 'refund' || 'reversal' || 'subsidy' => '+',
  'debit' => '-',
  _ => '',
};

String _money(int amountMinor, String currency) {
  final sign = amountMinor < 0 ? '-' : '';
  final absolute = amountMinor.abs();
  final major = absolute ~/ 100;
  final minor = (absolute % 100).toString().padLeft(2, '0');
  final symbol = currency == 'CNY' ? '¥' : '$currency ';
  return '$sign$symbol$major.$minor';
}

String _maskCardNumber(String cardNumber) {
  if (cardNumber.length <= 4) return '••••';
  return '•••• ${cardNumber.substring(cardNumber.length - 4)}';
}

String _cardStatusText(String status) => switch (status) {
  'active' => '状态正常',
  'frozen' => '已冻结',
  'lost' => '已挂失',
  'cancelled' => '已注销',
  _ => '状态未知',
};

String _balanceErrorText(String status) => switch (status) {
  'failed' => '余额查询失败，当前数值可能不是最新结果。',
  'pending' => '余额仍在处理中，请稍后重试。',
  _ => '余额状态未知，请重新查询。',
};

String _transactionStatusText(String status) => switch (status) {
  'final' => '已完成',
  'pending' => '处理中',
  'failed' => '失败',
  'cancelled' => '已取消',
  _ => '状态未知',
};

String _formatTimestamp(String value) {
  final date = DateTime.tryParse(value);
  if (date == null) return value;
  return formatLocalDateTime(date);
}

// ===========================================================================
// 考试 / 图书借阅（用户按需）
// ===========================================================================

class ExamSection extends StatefulWidget {
  const ExamSection({super.key});

  @override
  State<ExamSection> createState() => _ExamSectionState();
}

class _ExamSectionState extends State<ExamSection>
    with _CachedSection<ExamSection, ExamList> {
  @override
  String get cacheCapability => 'exam.list';
  @override
  ExamList? decodeCache(Object? value) => examListFromDynamic(value);
  @override
  void applyCache(ExamList data) {
    _data = data;
    _phase = _Phase.loaded;
  }

  @override
  void clearCache() {
    _data = null;
    _phase = _Phase.idle;
  }

  _Phase _phase = _Phase.idle;
  ExamList? _data;
  String? _error;

  Future<void> _load() async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    setState(() => _phase = _Phase.loading);
    final outcome = await _runDecoded<ExamList>(
      context,
      session,
      'exam.list',
      decode: examListFromDynamic,
    );
    if (!mounted || !_isCurrentSession(this, session, generation)) return;
    setState(() {
      if (outcome.needLogin) {
        _phase = _data == null ? _Phase.needLogin : _Phase.loaded;
      } else if (outcome.error != null) {
        _phase = _data == null ? _Phase.error : _Phase.loaded;
        _error = outcome.error;
      } else {
        _phase = _Phase.loaded;
        _data = outcome.data;
      }
    });
  }

  Future<void> _login() async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final ok = await _promptVisibleLogin(context, session);
    if (_isCurrentSession(this, session, generation) && ok) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (data != null) {
      return withCacheTime(_ExamResultCard(data: data));
    }
    final l10n = AppLocalizations.of(context);
    return _PromptCard(
      title: l10n.homeExamTitle,
      summary: _querySummary(context, _phase),
      subtitle: l10n.homeExamPrompt,
      child: _PhaseBody(
        phase: _phase,
        error: _error,
        idleLabel: l10n.homeExamLoad,
        onLoad: _load,
        onLogin: _login,
      ),
    );
  }
}

class _ExamResultCard extends StatelessWidget {
  const _ExamResultCard({required this.data});

  final ExamList data;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final items = data.items ?? const <ExamListItems>[];
    return SectionCard(
      title: l10n.homeExamTitle,
      summary: CardSummary(
        items.firstOrNull?.courseName ?? l10n.homeExamEmpty,
        detail: items.firstOrNull?.examAt == null
            ? null
            : _formatTimestamp(items.first.examAt!),
      ),
      subtitle: data.term == null
          ? l10n.homeExamCount(items.length)
          : l10n.homeExamTermCount(data.term!, items.length),
      child: items.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(l10n.homeExamEmpty),
            )
          : Column(
              children: [
                for (final item in items)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.event_note_outlined),
                    title: Text(item.courseName),
                    subtitle: Text(
                      [
                        if (item.examAt != null) _formatTimestamp(item.examAt!),
                        if (item.campus != null) item.campus!,
                        if (item.building != null) item.building!,
                        if (item.room != null) item.room!,
                        if (item.examType != null) item.examType!,
                        if (item.changeReason != null) item.changeReason!,
                      ].join(' · '),
                    ),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (item.status != null)
                          Text(_examStatusText(l10n, item.status!)),
                        if (item.seat != null)
                          Text(
                            l10n.homeExamSeat(item.seat!),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class LibraryLoansSection extends StatefulWidget {
  const LibraryLoansSection({super.key});

  @override
  State<LibraryLoansSection> createState() => _LibraryLoansSectionState();
}

class _LibraryLoansSectionState extends State<LibraryLoansSection>
    with _CachedSection<LibraryLoansSection, LibraryLoans> {
  @override
  String get cacheCapability => 'library.loans';
  @override
  LibraryLoans? decodeCache(Object? value) => libraryLoansFromDynamic(value);
  @override
  void applyCache(LibraryLoans data) {
    _data = data;
    _phase = _Phase.loaded;
  }

  @override
  void clearCache() {
    _data = null;
    _phase = _Phase.idle;
  }

  _Phase _phase = _Phase.idle;
  LibraryLoans? _data;
  String? _error;

  Future<void> _load() async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    setState(() => _phase = _Phase.loading);
    final outcome = await _runDecoded<LibraryLoans>(
      context,
      session,
      'library.loans',
      decode: libraryLoansFromDynamic,
    );
    if (!mounted || !_isCurrentSession(this, session, generation)) return;
    setState(() {
      if (outcome.needLogin) {
        _phase = _data == null ? _Phase.needLogin : _Phase.loaded;
      } else if (outcome.error != null) {
        _phase = _data == null ? _Phase.error : _Phase.loaded;
        _error = outcome.error;
      } else {
        _phase = _Phase.loaded;
        _data = outcome.data;
      }
    });
  }

  Future<void> _login() async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final ok = await _promptVisibleLogin(context, session);
    if (_isCurrentSession(this, session, generation) && ok) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (data != null) {
      return withCacheTime(_LibraryLoansResultCard(data: data));
    }
    final l10n = AppLocalizations.of(context);
    return _PromptCard(
      title: l10n.homeLibraryLoansTitle,
      summary: _querySummary(context, _phase),
      subtitle: l10n.homeLibraryLoansPrompt,
      child: _PhaseBody(
        phase: _phase,
        error: _error,
        idleLabel: l10n.homeLibraryLoansLoad,
        onLoad: _load,
        onLogin: _login,
      ),
    );
  }
}

class _LibraryLoansResultCard extends StatelessWidget {
  const _LibraryLoansResultCard({required this.data});

  final LibraryLoans data;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SectionCard(
      title: l10n.homeLibraryLoansTitle,
      subtitle: l10n.homeLibraryLoansCount(data.items.length),
      summary: CardSummary(
        data.items.firstOrNull?.title ?? l10n.homeLibraryLoansEmpty,
        detail: data.items.isEmpty
            ? null
            : [
                l10n.homeLibraryLoansCount(data.items.length),
                l10n.homeLibraryLoansDue(
                  _formatTimestamp(data.items.first.dueAt),
                ),
                if (data.items.any((item) => item.overdue == true))
                  l10n.homeLibraryLoansOverdue,
              ].join(' · '),
      ),
      child: data.items.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(l10n.homeLibraryLoansEmpty),
            )
          : CardPreviewList(
              title: l10n.homeLibraryLoansTitle,
              children: [
                for (final item in data.items)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading:
                        HomeCardPresentation.of(context) == HomeCardSize.compact
                        ? null
                        : Icon(
                            item.overdue == true
                                ? Icons.warning_amber_rounded
                                : Icons.menu_book_outlined,
                            color: item.overdue == true
                                ? Theme.of(context).colorScheme.error
                                : null,
                          ),
                    title: Text(item.title),
                    subtitle: Text(
                      [
                        if (item.author != null) item.author!,
                        if (item.branch != null) item.branch!,
                        if (item.location != null) item.location!,
                        if (item.callNumber != null) item.callNumber!,
                        l10n.homeLibraryLoansDue(_formatTimestamp(item.dueAt)),
                        if (item.overdueFee != null)
                          l10n.homeLibraryLoansOverdueFee(
                            _money(
                              item.overdueFee!.amountMinor,
                              item.overdueFee!.currency,
                            ),
                          ),
                      ].join(' · '),
                    ),
                    trailing: item.overdue == true
                        ? Text(
                            l10n.homeLibraryLoansOverdue,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          )
                        : null,
                  ),
              ],
            ),
    );
  }
}

String _examStatusText(AppLocalizations l10n, String status) =>
    switch (status) {
      'scheduled' => l10n.homeExamStatusScheduled,
      'changed' => l10n.homeExamStatusChanged,
      'cancelled' => l10n.homeExamStatusCancelled,
      'completed' => l10n.homeExamStatusCompleted,
      _ => l10n.homeExamStatusUnknown,
    };

// ===========================================================================
// 共用外壳
// ===========================================================================

/// 引导态卡片与已加载数据复用客户端卡片布局（ADR-004 §2.1）。
class _PromptCard extends StatelessWidget {
  const _PromptCard({
    required this.title,
    required this.subtitle,
    required this.child,
    this.summary,
  });

  final Widget? summary;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => SectionCard(
    title: title,
    subtitle: subtitle,
    summary: summary,
    child: child,
  );
}

/// 按阶段渲染取数动作/状态；不含已加载内容（由各区自行渲染数据卡片）。
class _PhaseBody extends StatelessWidget {
  const _PhaseBody({
    required this.phase,
    required this.error,
    required this.idleLabel,
    required this.onLoad,
    required this.onLogin,
    this.loadingHidden = false,
  });

  final _Phase phase;
  final String? error;
  final String idleLabel;
  final VoidCallback onLoad;
  final VoidCallback onLogin;

  /// 课表等已内嵌 loading 行时可隐藏内联 spinner（此处始终展示，占位保留）。
  final bool loadingHidden;

  @override
  Widget build(BuildContext context) {
    switch (phase) {
      case _Phase.idle:
      case _Phase.loaded: // loaded 时本 body 仅用于「重新查询」入口
        return Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            onPressed: onLoad,
            icon: const Icon(Icons.download_outlined),
            label: Text(idleLabel),
          ),
        );
      case _Phase.loading:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 12),
              Text('正在取数…'),
            ],
          ),
        );
      case _Phase.needLogin:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('需要登录后查看'),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: onLogin,
              icon: const Icon(Icons.login),
              label: const Text('登录并查看'),
            ),
          ],
        );
      case _Phase.error:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              error ?? '加载失败',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: onLoad,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        );
    }
  }
}

String _formatDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

Widget? _querySummary(BuildContext context, _Phase phase) => switch (phase) {
  _Phase.loading => Text(AppLocalizations.of(context).homeCardLoading),
  _Phase.error => Text(AppLocalizations.of(context).campusLoadFailed),
  _Phase.needLogin => Text(AppLocalizations.of(context).homeCardNeedsLogin),
  _ => null,
};
