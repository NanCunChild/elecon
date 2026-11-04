/// Native timetable navigation and academic-calendar composition. Shared lifecycle lives in query_section.dart.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import '../../session/session_scope.dart';
import 'card_layout.dart';
import 'schedule_view.dart' show ScheduleCard;
import 'models.dart';
import 'schema_decode.dart';
import 'schedule_view.dart' show ScheduleWeekPicker, ScheduleWeekTransition;
import 'section_card.dart';

import 'query_section.dart';
import 'capability_source.dart';

class ScheduleSection extends StatefulWidget {
  const ScheduleSection({super.key, this.calendarEnabled = false});

  final bool calendarEnabled;

  @override
  State<ScheduleSection> createState() => _ScheduleSectionState();
}

class _ScheduleSectionState extends State<ScheduleSection>
    with CachedQuerySection<ScheduleSection, ScheduleWeek> {
  bool _opened = false;
  bool? _home;
  ScheduleWeek? _homeData;
  Timer? _staleTimer;
  DateTime? _autoRefreshAttempt;
  bool _refreshing = false;

  @override
  void onConfigurationRequired() => _phase = QueryPhase.needConfiguration;

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
          _autoRefreshAttempt == cacheFetchedAt) {
        return;
      }
      _autoRefreshAttempt = cacheFetchedAt;
      setState(() => cacheStale = true);
      unawaited(_load(background: true));
    }

    final until = cacheFreshUntil;
    if (cacheStale || (until != null && !until.isAfter(DateTime.now()))) {
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
      cacheRead++;
      cacheFetchedAt = null;
      if (!home) {
        // Every opening starts with the script's current-week query, not the
        // most recently viewed historical week.
        _manualWeek = false;
        _defaultQuery = true;
        _currentWeek = null;
        _calendarLoaded = false;
        _opened = false;
        _data = null;
        _phase = QueryPhase.idle;
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
        if (mounted && !_home! && _data == null && _phase == QueryPhase.idle) {
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
    _phase = QueryPhase.loaded;
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
    _phase = QueryPhase.idle;
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
    if (_phase == QueryPhase.loading ||
        week == _week ||
        week < 1 ||
        week > _maxWeek) {
      return;
    }
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final source = CapabilitySourceScope.maybeOf(context)?.source;
    _request++;
    setState(() {
      _week = week;
      _manualWeek = true;
      _data = null;
      cacheFetchedAt = null;
      _phase = QueryPhase.loading;
      _error = null;
    });
    await restoreCache();
    if (!mounted || !isCurrentQuery(this, session, generation, source)) return;
    if (_data == null) await _load();
  }

  QueryPhase _phase = QueryPhase.idle;
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
    final source = CapabilitySourceScope.maybeOf(context)?.source;
    setState(() => _refreshing = true);
    final result = await runDecoded<ScheduleWeek>(
      context,
      session,
      'schedule.week',
      params: {if (configure) 'configure': true},
      decode: scheduleWeekFromDynamic,
    );
    if (!isCurrentQuery(this, session, generation, source)) return;
    setState(() {
      _refreshing = false;
      if (result.data != null) _homeData = result.data;
      _phase = result.needConfiguration
          ? QueryPhase.needConfiguration
          : result.needLogin
          ? QueryPhase.needLogin
          : result.data == null
          ? QueryPhase.error
          : QueryPhase.loaded;
      _error = result.error;
    });
    await restoreCache();
  }

  Future<void> _load({bool background = false, bool configure = false}) async {
    if (_home!) return _loadHome(configure: configure);
    if (_refreshing) return;
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final source = CapabilitySourceScope.maybeOf(context)?.source;
    final request = ++_request;
    setState(() {
      _refreshing = background || _data != null;
      if (_data == null) _phase = QueryPhase.loading;
      _error = null;
    });
    if (_queryCurrentWeek) {
      final calendar = await runDecoded<CalendarAcademic>(
        context,
        session,
        'calendar.academic',
        params: {if (configure) 'configure': true},
        interactive: !background,
        decode: calendarAcademicFromDynamic,
      );
      if (!mounted ||
          request != _request ||
          !isCurrentQuery(this, session, generation, source)) {
        if (mounted && isCurrentQuery(this, session, generation, source)) {
          setState(() => _refreshing = false);
          await restoreCache();
          if (!_home! && _data == null && _phase == QueryPhase.loading) {
            await _load();
          }
        }
        return;
      }
      if (calendar.data == null) {
        setState(() {
          _refreshing = false;
          _phase = calendar.needConfiguration
              ? QueryPhase.needConfiguration
              : _data != null
              ? QueryPhase.loaded
              : calendar.needLogin
              ? QueryPhase.needLogin
              : QueryPhase.error;
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
    final outcome = await runDecoded<ScheduleWeek>(
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
    if (mounted && isCurrentQuery(this, session, generation, source)) {
      setState(() => _refreshing = false);
    }
    if (!mounted ||
        request != _request ||
        !isCurrentQuery(this, session, generation, source)) {
      if (mounted && isCurrentQuery(this, session, generation, source)) {
        await restoreCache();
        if (!_home! && _data == null && _phase == QueryPhase.loading) {
          await _load();
        }
      }
      return;
    }
    setState(() {
      if (outcome.needConfiguration) {
        _phase = QueryPhase.needConfiguration;
      } else if (outcome.needLogin) {
        _phase = QueryPhase.needLogin;
      } else if (outcome.error != null) {
        _phase = QueryPhase.error;
        _error = outcome.error;
      } else {
        _phase = QueryPhase.loaded;
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
    final source = CapabilitySourceScope.maybeOf(context)?.source;
    final ok = await promptVisibleLogin(
      context,
      session,
      capability: 'schedule.week',
    );
    if (!mounted || !isCurrentQuery(this, session, generation, source)) return;
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
                  querySummary(context, _phase) ??
                  CardSummary(l10n.scheduleTodayUnavailable),
              child: QueryPhaseBody(
                phase: _phase,
                error: _error,
                onLogin: _login,
                onConfigure: () => _loadHome(configure: true),
              ),
            );
    }
    final busy = _phase == QueryPhase.loading;
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
            schedule: _data,
            onChanged: _selectWeek,
          ),
        if (busy) const LinearProgressIndicator(),
        if (_phase == QueryPhase.needLogin ||
            _phase == QueryPhase.needConfiguration)
          QueryPhaseBody(
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
