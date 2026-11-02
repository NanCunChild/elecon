/// Native examination schedule query. Shared lifecycle lives in query_section.dart.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import '../../session/session_scope.dart';
import 'models.dart';
import 'schema_decode.dart';
import 'section_card.dart';

import 'query_section.dart';
import 'capability_source.dart';

class ExamSection extends StatefulWidget {
  const ExamSection({super.key});

  @override
  State<ExamSection> createState() => _ExamSectionState();
}

class _ExamSectionState extends State<ExamSection>
    with CachedQuerySection<ExamSection, ExamList> {
  @override
  void onConfigurationRequired() => _phase = QueryPhase.needConfiguration;

  @override
  String get cacheCapability => 'exam.list';
  @override
  ExamList? decodeCache(Object? value) => examListFromDynamic(value);
  @override
  void applyCache(ExamList data) {
    _data = data;
    _phase = QueryPhase.loaded;
  }

  @override
  void clearCache() {
    _data = null;
    _phase = QueryPhase.idle;
  }

  QueryPhase _phase = QueryPhase.idle;
  ExamList? _data;
  String? _error;

  Future<void> _load({bool configure = false}) async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final source = CapabilitySourceScope.maybeOf(context)?.source;
    setState(() => _phase = QueryPhase.loading);
    final outcome = await runDecoded<ExamList>(
      context,
      session,
      'exam.list',
      params: {if (configure) 'configure': true},
      decode: examListFromDynamic,
    );
    if (!mounted || !isCurrentQuery(this, session, generation, source)) return;
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
      }
    });
  }

  Future<void> _login() async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final source = CapabilitySourceScope.maybeOf(context)?.source;
    final ok = await promptVisibleLogin(
      context,
      session,
      capability: 'exam.list',
    );
    if (isCurrentQuery(this, session, generation, source) && ok) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (data != null) {
      return withCacheTime(
        _ExamResultCard(
          data: data,
          trailing: SectionRefreshButton(
            onPressed: _phase == QueryPhase.loading ? null : _load,
          ),
        ),
      );
    }
    final l10n = AppLocalizations.of(context);
    return QueryPromptCard(
      title: l10n.homeExamTitle,
      trailing: SectionRefreshButton(
        onPressed: _phase == QueryPhase.loading ? null : _load,
      ),
      summary: querySummary(context, _phase),
      subtitle: l10n.homeExamPrompt,
      child: QueryPhaseBody(
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
            : formatQueryTimestamp(items.first.examAt!),
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
                        if (item.examAt != null)
                          formatQueryTimestamp(item.examAt!),
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
