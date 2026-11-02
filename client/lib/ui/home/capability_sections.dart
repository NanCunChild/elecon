/// 首页「按需取数」能力区：成绩 / 课表 / 空教室 / 一卡通 / 考试 / 图书借阅。
///
/// 各能力所需凭证由 manifest 声明，[SessionController.runCapability] 内部按需确保。
/// ADR-038 声明的缓存可立即恢复，后台刷新不弹交互；UI 不接触凭证值（红线 #1）。
/// 手动取数的 auth 失败复用 [runSchoolLogin]，成功后重试能力。
///
/// 卡片由标准 schema 选择并在客户端固定实现，不接受 adapter 渲染描述（ADR-004 §2.1）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:elecon_contract/card_qr.dart';

import 'package:flutter/material.dart';

import '../../core/adapter_service.dart';
import '../../core/card_spending.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import '../../session/session_scope.dart';
import '../login/login_flow.dart';
import '../login/webview_login_page.dart';
import 'display_date.dart';
import 'card_layout.dart';
import 'card_preview_list.dart';
import 'card_spending_view.dart';
import 'home_page.dart' show GradesCard, ScheduleCard, NoticeCard;
import 'models.dart';
import 'schema_decode.dart';
import 'schedule_view.dart' show ScheduleWeekPicker, ScheduleWeekTransition;
import 'section_card.dart';

/// 一次能力取数 + 解码的归一化结果。
class _Outcome<T> {
  const _Outcome({this.data, this.needLogin = false, this.error, this.reason});

  bool get needConfiguration => reason == 'configuration_required';

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
  bool interactive = true,
  required T? Function(Object?) decode,
}) async {
  final run = await session.runCapability(
    capability,
    params: params,
    interactive: interactive,
  );
  if (!run.ok) {
    if (run.reason == 'configuration_required') {
      return const _Outcome(reason: 'configuration_required');
    }
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
  bool interactive = true,
  required T? Function(Object?) decode,
}) async {
  final first = await _runOnceDecoded(
    session,
    capability,
    params: params,
    interactive: interactive,
    decode: decode,
  );
  if (context.mounted) {
    final l10n = AppLocalizations.of(context);
    final message = switch (first.reason) {
      'configuration_required' => l10n.capabilityConfigurationRequired,
      'network_denied' => l10n.scriptsNetworkDenied,
      'source_response_invalid' => l10n.scriptsSourceResponseInvalid,
      'authentication_timeout' => l10n.scriptsAuthenticationTimeout,
      'input_cancelled' => l10n.scriptsInputCancelled,
      _ => null,
    };
    if (message != null) return _Outcome(error: message, reason: first.reason);
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

enum _Phase { idle, loading, loaded, needLogin, needConfiguration, error }

/// ADR-038: restore validated current-school data independently of widget life.
/// Background writes notify SessionScope; failed refreshes never replace data.
mixin _CachedSection<W extends StatefulWidget, D> on State<W> {
  SessionController? _cacheSession;
  String? _cacheSchool;
  int? _cacheRevision;
  int? _cacheGeneration;
  int _cacheRead = 0;
  DateTime? _cacheFetchedAt;
  DateTime? _cacheFreshUntil;
  bool _cacheStale = false;
  Map<String, dynamic> _restoredParams = const {};

  String get cacheCapability;
  D? decodeCache(Object? value);
  Map<String, dynamic>? get cacheParams => null;
  bool get useLatestCache => cacheParams == null;
  void applyCache(D data);
  void clearCache();
  void onCacheRestored() {}
  void onConfigurationRequired() {}

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
        final needsConfiguration = await session.capabilityNeedsConfiguration(
          cacheCapability,
          params: cacheParams,
        );
        if (!_isCurrentSession(this, session, generation) ||
            read != _cacheRead) {
          return;
        }
        if (needsConfiguration) {
          setState(onConfigurationRequired);
          return;
        }
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
        _cacheFreshUntil = cached.freshUntil;
        _cacheStale = cached.isStale;
        applyCache(decoded);
      });
      onCacheRestored();
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
                  formatUpdateTime(
                    _cacheFetchedAt!,
                    AppLocalizations.of(context),
                  ),
                )
              : AppLocalizations.of(context).homeDataUpdatedAt(
                  formatUpdateTime(
                    _cacheFetchedAt!,
                    AppLocalizations.of(context),
                  ),
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

class NoticeSection extends StatefulWidget {
  const NoticeSection({super.key, this.initialData, this.generation});
  final NoticeList? initialData;
  final int? generation;
  @override
  State<NoticeSection> createState() => _NoticeSectionState();
}

class _NoticeSectionState extends State<NoticeSection>
    with _CachedSection<NoticeSection, NoticeList> {
  NoticeList? _data;
  _Phase _phase = _Phase.idle;
  String? _error;
  bool _prepared = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = SessionScope.of(context);
    if (_data == null &&
        widget.initialData != null &&
        widget.generation == session.trustedScriptViewGeneration) {
      applyCache(widget.initialData!);
    }
    if (_prepared) return;
    _prepared = true;
    final generation = session.trustedScriptViewGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!_isCurrentSession(this, session, generation)) return;
      await restoreCache();
      if (!_isCurrentSession(this, session, generation) ||
          _data != null ||
          _phase != _Phase.idle) {
        return;
      }
      final school = session.selectedSchool;
      if (school == null) return;
      final provider = (await session.scriptRegistry).provider(
        school.id,
        'notice.list',
      );
      if (!_isCurrentSession(this, session, generation)) return;
      if (provider?.manifest.home.any(
            (query) => query.capability == 'notice.list' && query.preload,
          ) ==
          true) {
        return;
      }
      await _load(interactive: false);
    });
  }

  @override
  void didUpdateWidget(covariant NoticeSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialData != null &&
        widget.initialData != oldWidget.initialData &&
        widget.generation ==
            SessionScope.of(context).trustedScriptViewGeneration) {
      applyCache(widget.initialData!);
    }
  }

  @override
  String get cacheCapability => 'notice.list';
  @override
  NoticeList? decodeCache(Object? value) => noticeListFromDynamic(value);
  @override
  void applyCache(NoticeList data) {
    _data = data;
    _phase = _Phase.loaded;
  }

  @override
  void clearCache() {
    _prepared = false;
    _data = null;
    _phase = _Phase.idle;
    _error = null;
  }

  @override
  void onConfigurationRequired() => _phase = _Phase.needConfiguration;

  Future<void> _load({bool configure = false, bool interactive = true}) async {
    if (_phase == _Phase.loading) return;
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    setState(() => _phase = _Phase.loading);
    final result = await _runDecoded<NoticeList>(
      context,
      session,
      'notice.list',
      interactive: interactive,
      params: {if (configure) 'configure': true},
      decode: noticeListFromDynamic,
    );
    if (!_isCurrentSession(this, session, generation)) return;
    setState(() {
      _phase = result.needConfiguration
          ? _Phase.needConfiguration
          : result.needLogin
          ? _Phase.needLogin
          : result.data == null
          ? _Phase.error
          : _Phase.loaded;
      _error = result.error;
      if (result.data != null) _data = result.data;
    });
    if (result.data != null) await restoreCache();
  }

  Future<void> _login() async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    if (await _promptVisibleLogin(context, session) &&
        _isCurrentSession(this, session, generation)) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final refresh = SectionRefreshButton(
      onPressed: _phase == _Phase.loading ? null : _load,
    );
    if (_data != null) {
      return withCacheTime(NoticeCard(_data!, trailing: refresh));
    }
    return SectionCard(
      title: l10n.homeNoticeTitle,
      trailing: refresh,
      summary:
          _querySummary(context, _phase) ?? Text(l10n.homeNoticeUnavailable),
      child: _PhaseBody(
        phase: _phase,
        error: _error,
        onLogin: _login,
        onConfigure: () => _load(configure: true),
      ),
    );
  }
}

class GradesSection extends StatefulWidget {
  const GradesSection({super.key});

  @override
  State<GradesSection> createState() => _GradesSectionState();
}

class _GradesSectionState extends State<GradesSection>
    with _CachedSection<GradesSection, GradesList> {
  @override
  void onConfigurationRequired() => _phase = _Phase.needConfiguration;

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

  Future<void> _load({bool configure = false}) async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    setState(() => _phase = _Phase.loading);
    final outcome = await _runDecoded<GradesList>(
      context,
      session,
      'grades.list',
      params: {if (configure) 'configure': true},
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
      if (outcome.needConfiguration) {
        _phase = _Phase.needConfiguration;
      } else if (outcome.needLogin) {
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
      return withCacheTime(
        GradesCard(
          _data!,
          summary: _summary,
          trailing: SectionRefreshButton(
            onPressed: _phase == _Phase.loading ? null : _load,
          ),
        ),
      );
    }
    return _PromptCard(
      title: '成绩',
      trailing: SectionRefreshButton(
        onPressed: _phase == _Phase.loading ? null : _load,
      ),
      summary: _querySummary(context, _phase),
      subtitle: '登录后查看本学期成绩单',
      child: _PhaseBody(
        phase: _phase,
        error: _error,
        onLogin: _login,
        onConfigure: () => _load(configure: true),
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
  bool _opened = false;
  bool? _home;
  ScheduleWeek? _homeData;
  Timer? _staleTimer;
  DateTime? _autoRefreshAttempt;
  bool _refreshing = false;

  @override
  void onConfigurationRequired() => _phase = _Phase.needConfiguration;

  @override
  void dispose() {
    _staleTimer?.cancel();
    super.dispose();
  }

  @override
  void onCacheRestored() {
    _staleTimer?.cancel();
    if (_home! || _data == null) return;
    void refresh() {
      if (!mounted ||
          _home! ||
          _refreshing ||
          _autoRefreshAttempt == _cacheFetchedAt) {
        return;
      }
      _autoRefreshAttempt = _cacheFetchedAt;
      setState(() => _cacheStale = true);
      unawaited(_load(background: true));
    }

    final until = _cacheFreshUntil;
    if (_cacheStale || (until != null && !until.isAfter(DateTime.now()))) {
      refresh();
    } else if (until != null) {
      _staleTimer = Timer(until.difference(DateTime.now()), refresh);
    }
  }

  @override
  void didChangeDependencies() {
    final presentation = HomeCardPresentation.maybeOf(context);
    final home = presentation != null && !presentation.isPage;
    final changedPresentation = _home != null && _home != home;
    _home = home;
    if (changedPresentation) {
      // The board lends this state to the page. Its selected week and the
      // default home query have independent cache addresses and timestamps.
      _cacheRead++;
      _cacheFetchedAt = null;
      if (!home) {
        // Every opening starts with the script's current-week query, not the
        // most recently viewed historical week.
        _manualWeek = false;
        _defaultQuery = true;
        _currentWeek = null;
        _calendarLoaded = false;
        _opened = false;
        _data = null;
        _phase = _Phase.idle;
        _request++;
      }
    }
    super.didChangeDependencies();
    if (changedPresentation) unawaited(restoreCache());
    if (!_opened && (HomeCardPresentation.maybeOf(context)?.isPage ?? false)) {
      _opened = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted || _home!) return;
        await restoreCache();
        if (mounted && !_home! && _data == null && _phase == _Phase.idle) {
          await _load();
        }
      });
    }
  }

  @override
  String get cacheCapability => 'schedule.week';
  @override
  ScheduleWeek? decodeCache(Object? value) => scheduleWeekFromDynamic(value);
  @override
  void applyCache(ScheduleWeek data) {
    if (_home!) {
      _homeData = data;
      return;
    }
    if (!_manualWeek && _defaultQuery) _currentWeek = data.week;
    _data = data;
    _phase = _Phase.loaded;
    _week = data.week;
    _term = data.term;
    _calendarLoaded = true;
    _rememberPreviews(data);
  }

  @override
  void clearCache() {
    _staleTimer?.cancel();
    _autoRefreshAttempt = null;
    _refreshing = false;
    _homeData = null;
    _data = null;
    _phase = _Phase.idle;
    _week = 1;
    _currentWeek = null;
    _request++;
    _term = null;
    _calendarLoaded = false;
    _defaultQuery = true;
    _manualWeek = false;
    _previews.clear();
    _previewTerm = null;
  }

  @override
  bool get useLatestCache => false;
  @override
  Map<String, dynamic>? get cacheParams =>
      _home! || (!_manualWeek && _defaultQuery)
      ? const {}
      : {'week': _week, if (_term != null) 'term': _term};

  int get _maxWeek =>
      _previews.keys.fold(_week > 25 ? _week : 25, (a, b) => a > b ? a : b);
  final _previews = <int, ScheduleWeekWeekPreviews>{};
  String? _previewTerm;

  void _rememberPreviews(ScheduleWeek data) {
    if (_previewTerm != data.term) _previews.clear();
    _previewTerm = data.term;
    for (final preview in data.weekPreviews ?? <ScheduleWeekWeekPreviews>[]) {
      _previews[preview.week] = preview;
    }
    _previews[data.week] = ScheduleWeekWeekPreviews(
      week: data.week,
      days: [
        for (final day in data.days)
          ScheduleWeekWeekPreviewsDays(
            dayOfWeek: day.dayOfWeek,
            courseCount: day.slots
                .where(
                  (s) =>
                      (s.weeks == null || s.weeks!.contains(data.week)) &&
                      !(s.weekExceptions?.contains(data.week) ?? false),
                )
                .length,
          ),
      ],
    );
  }

  Future<void> _selectWeek(int week) async {
    if (_phase == _Phase.loading ||
        week == _week ||
        week < 1 ||
        week > _maxWeek) {
      return;
    }
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    _request++;
    setState(() {
      _week = week;
      _manualWeek = true;
      _data = null;
      _cacheFetchedAt = null;
      _phase = _Phase.loading;
      _error = null;
    });
    await restoreCache();
    if (!mounted || !_isCurrentSession(this, session, generation)) return;
    if (_data == null) await _load();
  }

  _Phase _phase = _Phase.idle;
  int _week = 1;
  int? _currentWeek;
  bool _calendarLoaded = false;
  bool _defaultQuery = true;
  bool _manualWeek = false;
  int _request = 0;
  String? _term;
  bool get _queryCurrentWeek => widget.calendarEnabled && !_manualWeek;
  bool get _needsCurrentWeek => _queryCurrentWeek && !_calendarLoaded;
  ScheduleWeek? _data;
  String? _error;

  Future<void> _loadHome({bool configure = false}) async {
    if (_refreshing) return;
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    setState(() => _refreshing = true);
    final result = await _runDecoded<ScheduleWeek>(
      context,
      session,
      'schedule.week',
      params: {if (configure) 'configure': true},
      decode: scheduleWeekFromDynamic,
    );
    if (!_isCurrentSession(this, session, generation)) return;
    setState(() {
      _refreshing = false;
      if (result.data != null) _homeData = result.data;
      _phase = result.needConfiguration
          ? _Phase.needConfiguration
          : result.needLogin
          ? _Phase.needLogin
          : result.data == null
          ? _Phase.error
          : _Phase.loaded;
      _error = result.error;
    });
    await restoreCache();
  }

  Future<void> _load({bool background = false, bool configure = false}) async {
    if (_home!) return _loadHome(configure: configure);
    if (_refreshing) return;
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final request = ++_request;
    setState(() {
      _refreshing = background || _data != null;
      if (_data == null) _phase = _Phase.loading;
      _error = null;
    });
    if (_queryCurrentWeek) {
      final calendar = await _runDecoded<CalendarAcademic>(
        context,
        session,
        'calendar.academic',
        params: {if (configure) 'configure': true},
        interactive: !background,
        decode: calendarAcademicFromDynamic,
      );
      if (!mounted ||
          request != _request ||
          !_isCurrentSession(this, session, generation)) {
        if (mounted && _isCurrentSession(this, session, generation)) {
          setState(() => _refreshing = false);
          await restoreCache();
          if (!_home! && _data == null && _phase == _Phase.loading) {
            await _load();
          }
        }
        return;
      }
      if (calendar.data == null) {
        setState(() {
          _refreshing = false;
          _phase = calendar.needConfiguration
              ? _Phase.needConfiguration
              : _data != null
              ? _Phase.loaded
              : calendar.needLogin
              ? _Phase.needLogin
              : _Phase.error;
          _error = calendar.needConfiguration ? null : calendar.error;
        });
        return;
      }
      setState(() {
        _currentWeek = calendar.data!.currentWeek;
        _week = _currentWeek ?? 1;
        _term = calendar.data!.term;
        _calendarLoaded = true;
      });
    }
    // ADR-038 lets a trusted script resolve its current week without a
    // separate calendar capability. V1 retains its explicit-week input.
    _defaultQuery =
        !_manualWeek &&
        !widget.calendarEnabled &&
        (session.selectedSchool?.adapterId.startsWith('script:') ?? false);
    final outcome = await _runDecoded<ScheduleWeek>(
      context,
      session,
      'schedule.week',
      interactive: !background,
      params: {
        if (configure) 'configure': true,
        if (!_defaultQuery) 'week': _week,
        if (!_defaultQuery && _term != null) 'term': _term,
      },
      decode: scheduleWeekFromDynamic,
    );
    if (mounted && _isCurrentSession(this, session, generation)) {
      setState(() => _refreshing = false);
    }
    if (!mounted ||
        request != _request ||
        !_isCurrentSession(this, session, generation)) {
      if (mounted && _isCurrentSession(this, session, generation)) {
        await restoreCache();
        if (!_home! && _data == null && _phase == _Phase.loading) await _load();
      }
      return;
    }
    setState(() {
      if (outcome.needConfiguration) {
        _phase = _Phase.needConfiguration;
      } else if (outcome.needLogin) {
        _phase = _Phase.needLogin;
      } else if (outcome.error != null) {
        _phase = _Phase.error;
        _error = outcome.error;
      } else {
        _phase = _Phase.loaded;
        _data = outcome.data;
        if (_data != null) {
          if (_defaultQuery) _currentWeek = _data!.week;
          _week = _data!.week;
          _term = _data!.term;
          _calendarLoaded = true;
          _rememberPreviews(_data!);
        }
      }
    });
    // Cache timestamps belong to the successful source request. A refresh may
    // finish after a local week change; restore the currently selected week.
    if (outcome.data != null) await restoreCache();
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
    final l10n = AppLocalizations.of(context);
    if (_home!) {
      return _homeData != null
          ? withCacheTime(
              ScheduleCard(
                _homeData!,
                trailing: SectionRefreshButton(
                  onPressed: _refreshing ? null : _loadHome,
                ),
              ),
            )
          : SectionCard(
              title: l10n.homeScheduleTitle,
              trailing: SectionRefreshButton(
                onPressed: _refreshing ? null : _loadHome,
              ),
              summary:
                  _querySummary(context, _phase) ??
                  CardSummary(l10n.scheduleTodayUnavailable),
              child: _PhaseBody(
                phase: _phase,
                error: _error,
                onLogin: _login,
                onConfigure: () => _loadHome(configure: true),
              ),
            );
    }
    final busy = _phase == _Phase.loading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.homeScheduleTitle,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            IconButton(
              key: const ValueKey('schedule-refresh'),
              tooltip: l10n.homeRefresh,
              onPressed: busy || _refreshing ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        if (_needsCurrentWeek)
          TextButton(
            onPressed: busy ? null : () => setState(() => _manualWeek = true),
            child: Text(l10n.homeScheduleSelectWeek),
          )
        else
          ScheduleWeekPicker(
            week: _week,
            currentWeek: _currentWeek,
            maxWeek: _maxWeek,
            enabled: !busy,
            previews: _previews.values.toList(),
            onChanged: _selectWeek,
          ),
        if (busy) const LinearProgressIndicator(),
        if (_phase == _Phase.needLogin || _phase == _Phase.needConfiguration)
          _PhaseBody(
            phase: _phase,
            error: _error,
            onLogin: _login,
            onConfigure: () => _load(configure: true),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ScheduleWeekTransition(
          week: _data?.week,
          child: _data == null
              ? const SizedBox.shrink()
              : withCacheTime(
                  ScheduleCard(
                    _data!,
                    onWeekChanged: busy ? null : _selectWeek,
                    maxWeek: _maxWeek,
                  ),
                ),
        ),
        if (_refreshing) const LinearProgressIndicator(),
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
  bool _prepared = false;
  String _room = "";
  @override
  void onConfigurationRequired() => _availPhase = _Phase.needConfiguration;

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
    if (_selected?.buildingId != null) 'buildingId': _selected!.buildingId,
    if (_selected != null) 'building': _selected!.building,
    if (_selected?.campus != null) 'campus': _selected!.campus,
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
    _prepared = false;
    _room = "";
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
      _buildingsPhase = _buildings.isEmpty ? _Phase.error : _Phase.loaded;
      if (_buildings.isEmpty) {
        _buildingsError = AppLocalizations.of(context).classroomNoBuildings;
      }
      if (_selected != null) {
        final selected = _selected!;
        _selected = _buildings
            .where(
              (item) => selected.buildingId != null
                  ? item.buildingId == selected.buildingId
                  : item.building == selected.building,
            )
            .firstOrNull;
      }
      if (_selected == null) {
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_prepared &&
        (HomeCardPresentation.maybeOf(context)?.isPage ?? false)) {
      _prepared = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await restoreCache();
        if (mounted && _buildingsPhase == _Phase.idle) await _loadBuildings();
      });
    }
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

  Future<void> _loadBuildings({bool configure = false}) async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    setState(() => _buildingsPhase = _Phase.loading);
    final outcome = await _runDecoded<ClassroomBuildings>(
      context,
      session,
      'classroom.buildings',
      params: {if (configure) 'configure': true},
      decode: classroomBuildingsFromDynamic,
    );
    if (!mounted || !_isCurrentSession(this, session, generation)) return;
    setState(() {
      if (outcome.needConfiguration) {
        _buildingsPhase = _Phase.needConfiguration;
      } else if (outcome.needLogin) {
        _buildingsPhase = _Phase.needLogin;
      } else if (outcome.error != null) {
        _buildingsPhase = _Phase.error;
        _buildingsError = outcome.error;
      } else {
        _buildingsPhase = _Phase.loaded;
        _buildings = outcome.data?.items ?? const [];
        if (_buildings.isEmpty) {
          _buildingsPhase = _Phase.error;
          _buildingsError = AppLocalizations.of(context).classroomNoBuildings;
        }
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

  Future<void> _loadAvailable({bool configure = false}) async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final building = _selected;
    if (building == null) return;
    setState(() => _availPhase = _Phase.loading);
    final params = <String, dynamic>{
      'date': _formatDate(_date),
      if (configure) 'configure': true,
    };
    if (building.buildingId != null && building.buildingId!.isNotEmpty) {
      params['buildingId'] = building.buildingId;
      params['building'] = building.building;
      if (building.campus != null) params['campus'] = building.campus;
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
      if (outcome.needConfiguration) {
        _availPhase = _Phase.needConfiguration;
      } else if (outcome.needLogin) {
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
      return withCacheTime(
        _ClassroomResultCard(
          data: _avail!,
          trailing: SectionRefreshButton(
            onPressed:
                _availPhase == _Phase.loading ||
                    _buildingsPhase == _Phase.loading
                ? null
                : () async {
                    if (_selected == null) await _loadBuildings();
                    if (mounted && _selected != null) await _loadAvailable();
                  },
          ),
        ),
      );
    }
    // 教学楼未就绪：先引导取列表（可能触发登录）。
    if (_buildingsPhase != _Phase.loaded) {
      return Column(
        children: [
          _PromptCard(
            title: '空教室',
            trailing: SectionRefreshButton(
              onPressed: _buildingsPhase == _Phase.loading
                  ? null
                  : _loadBuildings,
            ),
            summary: _querySummary(context, _buildingsPhase),
            subtitle: AppLocalizations.of(context).classroomPreparing,
            child: _PhaseBody(
              phase: _buildingsPhase,
              error: _buildingsError,

              onLogin: _loginThenBuildings,
              onConfigure: () => _loadBuildings(configure: true),
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
          trailing: SectionRefreshButton(
            onPressed: busy ? null : _loadAvailable,
          ),
          summary: _querySummary(context, _availPhase),
          subtitle: AppLocalizations.of(context).classroomSearchHint,
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
                onConfigure: () => _loadAvailable(configure: true),

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
        if (_avail != null) ...[
          TextField(
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              labelText: AppLocalizations.of(context).classroomRoomHint,
            ),
            onChanged: (value) => setState(() => _room = value.trim()),
          ),
          withCacheTime(_ClassroomResultCard(data: _avail!, roomFilter: _room)),
        ],
      ],
    );
  }
}

class _ClassroomResultCard extends StatelessWidget {
  const _ClassroomResultCard({
    required this.data,
    this.roomFilter = "",
    this.trailing,
  });
  final Widget? trailing;
  final String roomFilter;

  final ClassroomAvailable data;

  @override
  Widget build(BuildContext context) {
    final items = (data.items ?? const <ClassroomAvailableItems>[])
        .where((item) => item.room.contains(roomFilter))
        .toList();
    final free = items
        .where(
          (i) =>
              i.occupied == false ||
              (i.occupied == null && i.status == 'available'),
        )
        .toList();
    return SectionCard(
      title: '空教室',
      trailing: trailing,
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
  const CardSection({
    super.key,
    this.transactionsEnabled = true,
    this.balanceEnabled = true,
    this.qrEnabled = false,
  });

  final bool balanceEnabled;
  final bool qrEnabled;

  final bool transactionsEnabled;

  @override
  State<CardSection> createState() => _CardSectionState();
}

class _CardSectionState extends State<CardSection>
    with _CachedSection<CardSection, CardBalance> {
  @override
  void onConfigurationRequired() => _phase = _Phase.needConfiguration;

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

  Future<void> _load({bool configure = false}) async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    setState(() => _phase = _Phase.loading);
    final outcome = await _runDecoded<CardBalance>(
      context,
      session,
      'card.balance',
      params: {if (configure) 'configure': true},
      decode: cardBalanceFromDynamic,
    );
    if (!mounted || !_isCurrentSession(this, session, generation)) return;
    setState(() {
      if (outcome.needConfiguration) {
        _phase = _Phase.needConfiguration;
      } else if (outcome.needLogin) {
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
    final l10n = AppLocalizations.of(context);
    final preview = HomeCardPresentation.isPreview(context);
    final presentation = HomeCardPresentation.maybeOf(context);
    final home = presentation != null && !presentation.isPage;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.balanceEnabled)
          if (data == null)
            _PhaseBody(
              phase: _phase,
              error: _error,
              onLogin: _login,
              onConfigure: () => _load(configure: true),
            )
          else if (data.errorStatus != null)
            Text(_balanceErrorText(data.errorStatus!))
          else ...[
            Text(
              _money(data.balance.amountMinor, data.balance.currency),
              style: Theme.of(
                context,
              ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            if (data.status != null) Text(_cardStatusText(data.status!)),
          ],
        if (!home && (widget.qrEnabled || widget.transactionsEnabled)) ...[
          if (widget.balanceEnabled) const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (widget.qrEnabled)
                FilledButton.tonalIcon(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(builder: (_) => const CardQrPage()),
                  ),
                  icon: const Icon(Icons.qr_code),
                  label: Text(l10n.cardQrShow),
                ),
              if (widget.transactionsEnabled)
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => const CardTransactionsPage(),
                    ),
                  ),
                  icon: const Icon(Icons.receipt_long_outlined),
                  label: Text(l10n.cardTransactions),
                ),
            ],
          ),
        ],
      ],
    );
    final card = SectionCard(
      title: l10n.homeCardTitle,
      trailing: widget.balanceEnabled
          ? SectionRefreshButton(
              onPressed: _phase == _Phase.loading ? null : _load,
            )
          : null,
      subtitle: data == null
          ? null
          : data.cardNumber == null
          ? l10n.cardAccountLabel
          : _maskCardNumber(data.cardNumber!),
      summary: data != null && widget.balanceEnabled
          ? CardSummary(
              data.errorStatus == null
                  ? _money(data.balance.amountMinor, data.balance.currency)
                  : _balanceErrorText(data.errorStatus!),
            )
          : widget.qrEnabled
          ? Text(l10n.cardQrHint)
          : widget.transactionsEnabled
          ? Text(l10n.cardTransactions)
          : _querySummary(context, _phase),
      child: content,
    );
    return data != null && (!preview || widget.balanceEnabled)
        ? withCacheTime(card)
        : card;
  }
}

/// QR data has no persistent cache and is destroyed on expiry/background/exit.
class CardQrPage extends StatefulWidget {
  const CardQrPage({super.key});
  @override
  State<CardQrPage> createState() => _CardQrPageState();
}

class _CardQrPageState extends State<CardQrPage> with WidgetsBindingObserver {
  Uint8List? _image;
  Timer? _expiry;
  String? _purpose;
  _Phase _phase = _Phase.idle;
  String? _error;
  SessionController? _session;
  int? _generation;
  int _request = 0;
  bool _started = false;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = SessionScope.of(context);
    if (!_started) {
      _started = true;
      _session = session;
      _generation = session.trustedScriptViewGeneration;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    } else if (!identical(session, _session) ||
        session.trustedScriptViewGeneration != _generation ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      _clear();
    }
  }

  void _clear() {
    _request++;
    _expiry?.cancel();
    if (_image != null) unawaited(MemoryImage(_image!).evict());
    _image = null;
    _purpose = null;
    _phase = _Phase.idle;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground && mounted) setState(_clear);
  }

  @override
  void dispose() {
    _clear();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _load({bool configure = false}) async {
    final session = _session!;
    if (!_foreground || session.trustedScriptViewGeneration != _generation) {
      return;
    }
    _clear();
    final request = _request;
    setState(() {
      _phase = _Phase.loading;
      _error = null;
    });
    final outcome = await _runDecoded<CardQr>(
      context,
      session,
      'card.qr',
      params: {if (configure) 'configure': true},
      decode: (raw) {
        if (raw is! Map ||
            raw['imageBase64'] is! String ||
            raw['issuedAt'] is! String ||
            raw['expiresAt'] is! String) {
          return null;
        }
        return CardQr(
          imageBase64: raw['imageBase64'] as String,
          issuedAt: raw['issuedAt'] as String,
          expiresAt: raw['expiresAt'] as String,
          purpose: raw['purpose'] as String?,
        );
      },
    );
    if (!mounted ||
        request != _request ||
        !_foreground ||
        !_isCurrentSession(this, session, _generation!)) {
      return;
    }
    try {
      if (outcome.data == null) {
        setState(() {
          _phase = outcome.needConfiguration
              ? _Phase.needConfiguration
              : outcome.needLogin
              ? _Phase.needLogin
              : _Phase.error;
          _error = outcome.error;
        });
        return;
      }
      final data = outcome.data!;
      final issued = DateTime.parse(data.issuedAt),
          expires = DateTime.parse(data.expiresAt),
          now = DateTime.now();
      if (!expires.isAfter(issued) ||
          !expires.isAfter(now) ||
          issued.isAfter(now.add(const Duration(seconds: 5)))) {
        throw const FormatException();
      }
      final bytes = base64Decode(data.imageBase64);
      const signature = [137, 80, 78, 71, 13, 10, 26, 10];
      if (bytes.length < 24 ||
          bytes.length > 262144 ||
          !List.generate(8, (i) => bytes[i] == signature[i]).every((v) => v)) {
        throw const FormatException();
      }
      final header = ByteData.sublistView(bytes);
      final width = header.getUint32(16), height = header.getUint32(20);
      if (width == 0 || height == 0 || width > 2048 || height > 2048) {
        throw const FormatException();
      }
      final remaining = expires.difference(now);
      setState(() {
        _image = bytes;
        _purpose = data.purpose;
        _phase = _Phase.loaded;
      });
      _expiry = Timer(
        remaining < const Duration(seconds: 60)
            ? remaining
            : const Duration(seconds: 60),
        () {
          if (mounted) setState(_clear);
        },
      );
    } catch (_) {
      setState(() {
        _phase = _Phase.error;
        _error = AppLocalizations.of(context).cardQrInvalid;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final session = SessionScope.of(context);
    final current =
        identical(session, _session) &&
        session.trustedScriptViewGeneration == _generation;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.cardQrShow),
        actions: [
          SectionRefreshButton(
            onPressed: current && _phase != _Phase.loading ? _load : null,
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!current)
                Text(l10n.homeCardDataChanged)
              else ...[
                if (_image != null)
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 320),
                      child: ColoredBox(
                        color: Colors.white,
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Image.memory(
                            _image!,
                            gaplessPlayback: false,
                            semanticLabel: l10n.cardQrShow,
                            errorBuilder: (_, _, _) => Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(
                                l10n.cardQrInvalid,
                                style: const TextStyle(color: Colors.black),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (_purpose != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(_purpose!, textAlign: TextAlign.center),
                  ),
                if (_phase == _Phase.idle) Text(l10n.cardQrExpired),
                _PhaseBody(
                  phase: _phase,
                  error: _error,
                  onConfigure: () => _load(configure: true),
                  onLogin: () async {
                    _clear();
                    final ok = await _promptVisibleLogin(
                      context,
                      session,
                      targetRef: 'card-session',
                    );
                    if (mounted && current && ok) await _load();
                  },
                ),
              ],
            ],
          ),
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
  static const _pageSize = 100;
  _Phase _phase = _Phase.loading;
  CardTransactions? _data;
  final _items = <CardTransactionsItems>[];
  String? _error;
  SessionController? _session;
  int? _generation;
  int _request = 0;
  int _page = 0;
  int _rangeDays = 30;
  bool _loadingMore = false;
  bool _hasMore = false;
  bool _complete = false;
  bool _loginRequired = false;
  DateTime _to = DateTime.now();
  DateTime? _fetchedAt;
  String? _snapshotAt;

  DateTime get _from => DateTime(_to.year, _to.month, _to.day - _rangeDays + 1);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = SessionScope.of(context);
    if (_session == null) {
      _session = session;
      _generation = session.trustedScriptViewGeneration;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    } else if (!identical(session, _session) ||
        session.trustedScriptViewGeneration != _generation) {
      _request++;
      _data = null;
      _items.clear();
      _error = null;
      _phase = _Phase.idle;
    }
  }

  @override
  void dispose() {
    _request++;
    super.dispose();
  }

  Future<void> _load({bool more = false, bool configure = false}) async {
    final session = _session!;
    if (!_isCurrentSession(this, session, _generation!)) return;
    if (more && (_loadingMore || !_hasMore)) return;
    final request = ++_request;
    final nextPage = more ? _page + 1 : 1;
    setState(() {
      _error = null;
      _loginRequired = false;
      _loadingMore = more;
      if (!more) {
        _phase = _Phase.loading;
        _data = null;
        _items.clear();
        _fetchedAt = null;
        _snapshotAt = null;
        _page = 0;
        _hasMore = false;
        _complete = false;
      }
    });
    final outcome = await _runDecoded<CardTransactions>(
      context,
      session,
      'card.transactions',
      params: {
        if (configure) 'configure': true,
        'from': formatLocalDate(_from),
        'to': formatLocalDate(_to),
        'page': nextPage,
        'size': _pageSize,
      },
      decode: cardTransactionsFromDynamic,
    );
    if (!mounted ||
        request != _request ||
        !_isCurrentSession(this, session, _generation!)) {
      return;
    }
    final l10n = AppLocalizations.of(context);
    setState(() {
      _loadingMore = false;
      if (outcome.needConfiguration) {
        _phase = _Phase.needConfiguration;
      } else if (outcome.needLogin) {
        _loginRequired = true;
        _phase = _data == null ? _Phase.needLogin : _Phase.loaded;
      } else if (outcome.error != null ||
          outcome.data == null ||
          (outcome.data!.page != null && outcome.data!.page != nextPage)) {
        _phase = _data == null ? _Phase.error : _Phase.loaded;
        _error = outcome.error ?? l10n.campusLoadFailed;
      } else {
        final data = outcome.data!;
        _phase = _Phase.loaded;
        _data = data;
        _page = nextPage;
        final ids = {
          for (final item in _items)
            if (item.transactionId != null && item.transactionId!.isNotEmpty)
              (item.currency, item.transactionId!),
        };
        final previousCount = _items.length;
        for (final item in data.items) {
          final id = item.transactionId;
          if (id == null || id.isEmpty || ids.add((item.currency, id))) {
            _items.add(item);
          }
        }
        _fetchedAt ??= DateTime.now();
        if (!more) _snapshotAt = data.snapshotAt;
        final total = data.total;
        _complete =
            data.hasNext != true &&
            data.cursor == null &&
            (total == null || _items.length >= total) &&
            (data.hasNext == false ||
                (total != null && _items.length >= total));
        _hasMore =
            !_complete &&
            data.items.isNotEmpty &&
            (!more || _items.length > previousCount) &&
            data.cursor == null &&
            (data.hasNext == true ||
                (total != null && _items.length < total) ||
                data.items.length >= _pageSize);
      }
    });
  }

  Future<void> _login() async {
    final session = _session!;
    if (!_isCurrentSession(this, session, _generation!)) return;
    final ok = await _promptVisibleLogin(
      context,
      session,
      targetRef: 'card-session',
    );
    if (!mounted || !_isCurrentSession(this, session, _generation!)) return;
    if (ok) await _load(more: _data != null);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final session = SessionScope.of(context);
    final current =
        identical(session, _session) &&
        session.trustedScriptViewGeneration == _generation;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.cardTransactions),
        actions: [
          SectionRefreshButton(
            onPressed: current && _phase != _Phase.loading && !_loadingMore
                ? () => _load()
                : null,
          ),
        ],
      ),
      body: SafeArea(
        child: !current
            ? Center(child: Text(l10n.homeCardDataChanged))
            : ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final days in [7, 30, 90])
                          ChoiceChip(
                            label: Text(l10n.cardSpendingLastDays(days)),
                            selected: _rangeDays == days,
                            onSelected: (_) {
                              if (_rangeDays == days) return;
                              setState(() {
                                _rangeDays = days;
                                _to = DateTime.now();
                              });
                              _load();
                            },
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      '${formatLocalDate(_from)} – ${formatLocalDate(_to)}',
                    ),
                  ),
                  if (_phase == _Phase.loading)
                    const Center(child: CircularProgressIndicator())
                  else if (_phase == _Phase.needLogin || _loginRequired)
                    Center(
                      child: FilledButton.icon(
                        onPressed: _login,
                        icon: const Icon(Icons.login),
                        label: Text(l10n.cardTransactionsLogin),
                      ),
                    ),
                  if (_phase == _Phase.needConfiguration)
                    _PhaseBody(
                      phase: _phase,
                      error: _error,
                      onLogin: _login,
                      onConfigure: () => _load(configure: true),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [Text(_error!, textAlign: TextAlign.center)],
                      ),
                    ),
                  if (_phase == _Phase.loaded) ...[
                    if (_items.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          l10n.cardSpendingNoRecords,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    CardSpendingView(
                      summary: CardSpendingSummary.fromTransactions(
                        _items,
                        from: _from,
                        to: _to,
                      ),
                      partial: !_complete,
                    ),
                    if (_fetchedAt != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: Text(
                          l10n.homeDataUpdatedAt(
                            formatUpdateTime(
                              DateTime.tryParse(_snapshotAt ?? '') ??
                                  _fetchedAt!,
                              l10n,
                            ),
                          ),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    for (final item in _items) ...[
                      _transactionTile(context, item),
                      const Divider(height: 1),
                    ],
                    if (!_complete)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(l10n.cardSpendingPartial),
                      ),
                    if (_loadingMore)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (_hasMore && !_loginRequired)
                      Center(
                        child: OutlinedButton.icon(
                          onPressed: () => _load(more: true),
                          icon: const Icon(Icons.expand_more),
                          label: Text(l10n.cardTransactionsLoadMore),
                        ),
                      ),
                  ],
                ],
              ),
      ),
    );
  }

  Widget _transactionTile(BuildContext context, CardTransactionsItems item) {
    final l10n = AppLocalizations.of(context);
    final sign = _directionSign(item.direction);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 12),
            child: Icon(
              sign == '+'
                  ? Icons.south_west
                  : sign == '-'
                  ? Icons.north_east
                  : Icons.swap_horiz,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.merchant ?? item.type ?? l10n.cardTransactionsEntry,
                  style: theme.textTheme.titleMedium,
                ),
                Text(
                  '$sign${formatCardMoney(context, item.amountMinor, item.currency)}',
                  style: theme.textTheme.titleMedium,
                ),
                Text(
                  [
                    _formatTimestamp(item.time),
                    if (item.location != null) item.location!,
                    if (item.status != null)
                      switch (item.status) {
                        'final' => l10n.cardTransactionFinal,
                        'pending' => l10n.cardTransactionPending,
                        'failed' => l10n.cardTransactionFailed,
                        'cancelled' => l10n.cardTransactionCancelled,
                        _ => l10n.cardTransactionUnknown,
                      },
                  ].join(' · '),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
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
  void onConfigurationRequired() => _phase = _Phase.needConfiguration;

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

  Future<void> _load({bool configure = false}) async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    setState(() => _phase = _Phase.loading);
    final outcome = await _runDecoded<ExamList>(
      context,
      session,
      'exam.list',
      params: {if (configure) 'configure': true},
      decode: examListFromDynamic,
    );
    if (!mounted || !_isCurrentSession(this, session, generation)) return;
    setState(() {
      if (outcome.needConfiguration) {
        _phase = _Phase.needConfiguration;
      } else if (outcome.needLogin) {
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
      return withCacheTime(
        _ExamResultCard(
          data: data,
          trailing: SectionRefreshButton(
            onPressed: _phase == _Phase.loading ? null : _load,
          ),
        ),
      );
    }
    final l10n = AppLocalizations.of(context);
    return _PromptCard(
      title: l10n.homeExamTitle,
      trailing: SectionRefreshButton(
        onPressed: _phase == _Phase.loading ? null : _load,
      ),
      summary: _querySummary(context, _phase),
      subtitle: l10n.homeExamPrompt,
      child: _PhaseBody(
        phase: _phase,
        error: _error,
        onLogin: _login,
        onConfigure: () => _load(configure: true),
      ),
    );
  }
}

class _ExamResultCard extends StatelessWidget {
  const _ExamResultCard({required this.data, this.trailing});
  final Widget? trailing;

  final ExamList data;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final items = data.items ?? const <ExamListItems>[];
    return SectionCard(
      trailing: trailing,
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
  void onConfigurationRequired() => _phase = _Phase.needConfiguration;

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

  Future<void> _load({bool configure = false}) async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    setState(() => _phase = _Phase.loading);
    final outcome = await _runDecoded<LibraryLoans>(
      context,
      session,
      'library.loans',
      params: {if (configure) 'configure': true},
      decode: libraryLoansFromDynamic,
    );
    if (!mounted || !_isCurrentSession(this, session, generation)) return;
    setState(() {
      if (outcome.needConfiguration) {
        _phase = _Phase.needConfiguration;
      } else if (outcome.needLogin) {
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
      return withCacheTime(
        _LibraryLoansResultCard(
          data: data,
          trailing: SectionRefreshButton(
            onPressed: _phase == _Phase.loading ? null : _load,
          ),
        ),
      );
    }
    final l10n = AppLocalizations.of(context);
    return _PromptCard(
      title: l10n.homeLibraryLoansTitle,
      trailing: SectionRefreshButton(
        onPressed: _phase == _Phase.loading ? null : _load,
      ),
      summary: _querySummary(context, _phase),
      subtitle: l10n.homeLibraryLoansPrompt,
      child: _PhaseBody(
        phase: _phase,
        error: _error,
        onLogin: _login,
        onConfigure: () => _load(configure: true),
      ),
    );
  }
}

class _LibraryLoansResultCard extends StatelessWidget {
  const _LibraryLoansResultCard({required this.data, this.trailing});
  final Widget? trailing;

  final LibraryLoans data;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SectionCard(
      trailing: trailing,
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
    this.trailing,
  });

  final Widget? trailing;
  final Widget? summary;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => SectionCard(
    title: title,
    subtitle: subtitle,
    summary: summary,
    trailing: trailing,
    child: child,
  );
}

/// 按阶段渲染取数动作/状态；不含已加载内容（由各区自行渲染数据卡片）。
class _PhaseBody extends StatelessWidget {
  const _PhaseBody({
    required this.phase,
    required this.error,
    required this.onLogin,
    this.onConfigure,
  });

  final _Phase phase;
  final String? error;
  final VoidCallback onLogin;
  final VoidCallback? onConfigure;

  @override
  Widget build(BuildContext context) {
    switch (phase) {
      case _Phase.idle:
      case _Phase.loaded:
        return const SizedBox.shrink();
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
      case _Phase.needConfiguration:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(AppLocalizations.of(context).capabilityConfigurationRequired),
            if (onConfigure != null)
              TextButton.icon(
                onPressed: onConfigure,
                icon: const Icon(Icons.edit_outlined),
                label: Text(
                  AppLocalizations.of(context).capabilityCompleteConfiguration,
                ),
              ),
          ],
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
  _Phase.needConfiguration => Text(
    AppLocalizations.of(context).capabilityConfigurationRequired,
  ),
  _Phase.needLogin => Text(AppLocalizations.of(context).homeCardNeedsLogin),
  _ => null,
};
