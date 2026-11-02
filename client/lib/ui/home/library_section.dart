/// Native current-loan query. Shared lifecycle lives in query_section.dart.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import '../../session/session_scope.dart';
import 'card_layout.dart';
import 'card_preview_list.dart';
import 'models.dart';
import 'schema_decode.dart';
import 'section_card.dart';

import 'query_section.dart';
import 'capability_source.dart';

class LibraryLoansSection extends StatefulWidget {
  const LibraryLoansSection({super.key});

  @override
  State<LibraryLoansSection> createState() => _LibraryLoansSectionState();
}

class _LibraryLoansSectionState extends State<LibraryLoansSection>
    with CachedQuerySection<LibraryLoansSection, LibraryLoans> {
  @override
  void onConfigurationRequired() => _phase = QueryPhase.needConfiguration;

  @override
  String get cacheCapability => 'library.loans';
  @override
  LibraryLoans? decodeCache(Object? value) => libraryLoansFromDynamic(value);
  @override
  void applyCache(LibraryLoans data) {
    _data = data;
    _phase = QueryPhase.loaded;
  }

  @override
  void clearCache() {
    _data = null;
    _phase = QueryPhase.idle;
  }

  QueryPhase _phase = QueryPhase.idle;
  LibraryLoans? _data;
  String? _error;

  Future<void> _load({bool configure = false}) async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final source = CapabilitySourceScope.maybeOf(context)?.source;
    setState(() => _phase = QueryPhase.loading);
    final outcome = await runDecoded<LibraryLoans>(
      context,
      session,
      'library.loans',
      params: {if (configure) 'configure': true},
      decode: libraryLoansFromDynamic,
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
      capability: 'library.loans',
    );
    if (isCurrentQuery(this, session, generation, source) && ok) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (data != null) {
      return withCacheTime(
        _LibraryLoansResultCard(
          data: data,
          trailing: SectionRefreshButton(
            onPressed: _phase == QueryPhase.loading ? null : _load,
          ),
        ),
      );
    }
    final l10n = AppLocalizations.of(context);
    return QueryPromptCard(
      title: l10n.homeLibraryLoansTitle,
      trailing: SectionRefreshButton(
        onPressed: _phase == QueryPhase.loading ? null : _load,
      ),
      summary: querySummary(context, _phase),
      subtitle: l10n.homeLibraryLoansPrompt,
      child: QueryPhaseBody(
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
                  formatQueryTimestamp(data.items.first.dueAt),
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
                        l10n.homeLibraryLoansDue(
                          formatQueryTimestamp(item.dueAt),
                        ),
                        if (item.overdueFee != null)
                          l10n.homeLibraryLoansOverdueFee(
                            formatQueryMoney(
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
