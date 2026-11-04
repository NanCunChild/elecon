/// Native grades query and optional official GPA summary. Shared lifecycle lives in query_section.dart.
library;

import 'capability_source.dart';
import 'card_layout.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import '../../session/session_scope.dart';
import 'result_cards.dart' show GradesCard;
import 'models.dart';
import 'schema_decode.dart';
import 'section_card.dart';

import 'query_section.dart';
import 'script_query_controls.dart';

class GradesSection extends StatefulWidget {
  const GradesSection({super.key});

  @override
  State<GradesSection> createState() => _GradesSectionState();
}

class _GradesSectionState extends State<GradesSection>
    with CachedQuerySection<GradesSection, GradesList> {
  @override
  void onConfigurationRequired() => _phase = QueryPhase.needConfiguration;

  @override
  String get cacheCapability => 'grades.list';
  @override
  Map<String, dynamic>? get cacheParams =>
      _selectedTerm == null ? null : {'term': _selectedTerm};
  @override
  GradesList? decodeCache(Object? value) => gradesListFromDynamic(value);
  @override
  void applyCache(GradesList data) {
    _selectedTerm ??= restoredParams['term'] as String?;
    _data = data;
    _phase = QueryPhase.loaded;
  }

  @override
  void clearCache() {
    _data = null;
    _phase = QueryPhase.idle;
    _summary = null;
    _selectedTerm = null;
    _filterError = null;
    _error = null;
    _termsLoading = false;
    _request++;
  }

  QueryPhase _phase = QueryPhase.idle;
  GradesList? _data;
  GpaSummary? _summary;
  String? _error;
  String? _selectedTerm;
  String? _filterError;
  bool _termsLoading = false;
  int _request = 0;

  Future<void> _load({bool configure = false}) async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final source = CapabilitySourceScope.maybeOf(context)?.source;
    final request = ++_request;
    final term = _selectedTerm;
    setState(() {
      _phase = QueryPhase.loading;
      _error = null;
    });
    final outcome = await runDecoded<GradesList>(
      context,
      session,
      'grades.list',
      params: {'term': ?term, if (configure) 'configure': true},
      decode: gradesListFromDynamic,
    );
    if (!mounted ||
        request != _request ||
        !isCurrentQuery(this, session, generation, source)) {
      return;
    }
    // 学校官方绩点汇总：**可选增强**，取不到不影响成绩单本身（ADR-001 §3.5——
    // 官方数存在时权威，不存在时卡片退到本机聚合并换标签）。故失败一律吞掉，
    // 不把它的 needLogin/error 冒泡成整个成绩区的失败态。
    final summary = outcome.data == null
        ? null
        : await _loadGpaSummary(session, term: term);
    if (!mounted ||
        request != _request ||
        !isCurrentQuery(this, session, generation, source)) {
      return;
    }
    setState(() {
      if (outcome.needConfiguration) {
        _phase = QueryPhase.needConfiguration;
      } else if (outcome.needLogin) {
        _phase = _data == null ? QueryPhase.needLogin : QueryPhase.loaded;
      } else if (outcome.error != null) {
        _phase = _data == null ? QueryPhase.error : QueryPhase.loaded;
        _error = outcome.error;
      } else {
        _phase = QueryPhase.loaded;
        _data = outcome.data;
        _summary = summary;
      }
    });
  }

  @override
  Future<void> restoreCache() async {
    await super.restoreCache();
    if (!mounted) return;
    final session = cacheSession;
    if (session == null) return;
    final read = cacheRead;
    final generation = session.trustedScriptViewGeneration;
    final source = CapabilitySourceScope.maybeOf(context)?.source;
    final cached = await CapabilitySourceScope.queriesOf(
      context,
      session,
    ).cachedCapability('gpa.summary', params: cacheParams);
    if (isCurrentQuery(this, session, generation, source) &&
        read == cacheRead &&
        cached != null) {
      final summary = gpaSummaryFromDynamic(cached.data);
      if (summary != null) setState(() => _summary = summary);
    }
  }

  /// 取 `gpa.summary`；任何失败都返回 null（见 [_load] 中的理由）。
  Future<GpaSummary?> _loadGpaSummary(
    SessionController session, {
    String? term,
  }) async {
    try {
      final run = await runDecoded<GpaSummary>(
        context,
        session,
        'gpa.summary',
        params: term == null ? null : {'term': term},
        decode: gpaSummaryFromDynamic,
      );
      return run.data;
    } on Object {
      return null;
    }
  }

  Future<void> _pickTerm() async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final source = CapabilitySourceScope.maybeOf(context)?.source;
    setState(() {
      _termsLoading = true;
      _filterError = null;
    });
    try {
      final selection = await pickScriptQueryControls(
        context,
        session,
        'grades.list',
        current: {'term': _selectedTerm ?? _data?.term},
      );
      if (!mounted || !isCurrentQuery(this, session, generation, source)) {
        return;
      }
      if (selection.supported) {
        setState(() => _termsLoading = false);
        if (selection.params != null) {
          setState(() {
            _selectedTerm = selection.params!['term'] as String?;
            _data = null;
            _summary = null;
            cacheRead++;
            cacheFetchedAt = null;
          });
          await _load();
        }
        return;
      }
    } catch (_) {
      if (mounted && isCurrentQuery(this, session, generation, source)) {
        setState(() {
          _termsLoading = false;
          _filterError = AppLocalizations.of(context).gradesTermsUnavailable;
        });
      }
      return;
    }
    final result = await runDecoded<TermList>(
      context,
      session,
      'term.list',
      params: const {'includePast': true},
      interactive: false,
      decode: termListFromDynamic,
    );
    if (!mounted || !isCurrentQuery(this, session, generation, source)) return;
    final l10n = AppLocalizations.of(context);
    final items = result.data?.items;
    setState(() {
      _termsLoading = false;
      if (items == null || items.isEmpty) {
        _filterError = result.error ?? l10n.gradesTermsUnavailable;
      }
    });
    if (items == null || items.isEmpty) return;
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l10n.gradesTermFilter),
        children: [
          for (final term in items)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, term.id),
              child: Row(
                children: [
                  Expanded(child: Text(term.name)),
                  if (term.id == _data?.term) const Icon(Icons.check),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected == null ||
        !mounted ||
        !isCurrentQuery(this, session, generation, source)) {
      return;
    }
    setState(() {
      _selectedTerm = selected;
      _data = null;
      _summary = null;
      cacheRead++;
      cacheFetchedAt = null;
    });
    await _load();
  }

  Future<void> _login() async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final source = CapabilitySourceScope.maybeOf(context)?.source;
    final ok = await promptVisibleLogin(
      context,
      session,
      capability: 'grades.list',
    );
    if (!mounted || !isCurrentQuery(this, session, generation, source)) return;
    if (ok) {
      await _load();
    }
  }

  Widget _filters() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextButton.icon(
        onPressed: _termsLoading || _phase == QueryPhase.loading
            ? null
            : _pickTerm,
        icon: const Icon(Icons.filter_list),
        label: Text(AppLocalizations.of(context).queryFilters),
      ),
      if (_filterError != null) Text(_filterError!),
    ],
  );

  @override
  Widget build(BuildContext context) {
    if (_data != null) {
      return withCacheTime(
        GradesCard(
          _data!,
          summary: _summary,
          controls: HomeCardPresentation.isPreview(context)
              ? null
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [_filters(), if (_error != null) Text(_error!)],
                ),
          trailing: SectionRefreshButton(
            onPressed: _phase == QueryPhase.loading ? null : _load,
          ),
        ),
      );
    }
    return QueryPromptCard(
      title: '成绩',
      trailing: SectionRefreshButton(
        onPressed: _phase == QueryPhase.loading ? null : _load,
      ),
      summary: querySummary(context, _phase),
      subtitle: '登录后查看本学期成绩单',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_selectedTerm != null) _filters(),
          QueryPhaseBody(
            phase: _phase,
            error: _error,
            onLogin: _login,
            onConfigure: () => _load(configure: true),
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// 课表（需 week；提供周次选择器）
// ===========================================================================
