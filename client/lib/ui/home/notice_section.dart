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

import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import '../../session/session_scope.dart';
import '../login/login_flow.dart';
import 'result_cards.dart' show NoticeCard;
import 'models.dart';
import 'schema_decode.dart';
import 'section_card.dart';

import 'query_section.dart';
import 'capability_source.dart';

class NoticeSection extends StatefulWidget {
  const NoticeSection({super.key, this.initialData, this.generation});
  final NoticeList? initialData;
  final int? generation;
  @override
  State<NoticeSection> createState() => _NoticeSectionState();
}

class _NoticeSectionState extends State<NoticeSection>
    with CachedQuerySection<NoticeSection, NoticeList> {
  NoticeList? _data;
  QueryPhase _phase = QueryPhase.idle;
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
    final source = CapabilitySourceScope.maybeOf(context)?.source;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!isCurrentQuery(this, session, generation, source)) return;
      await restoreCache();
      if (!isCurrentQuery(this, session, generation, source) ||
          _data != null ||
          _phase != QueryPhase.idle) {
        return;
      }
      final school = session.selectedSchool;
      if (school == null) return;
      final registry = await session.scriptRegistry;
      if (!mounted) return;
      final provider = source == null
          ? registry.provider(school.id, 'notice.list')
          : registry.find(source.packageId)?.package;
      if (!isCurrentQuery(this, session, generation, source)) return;
      if (provider?.manifest.home.any(
            (query) => query.capability == 'notice.list' && query.preload,
          ) ==
          true) {
        await session.waitForHomeRefresh();
        if (!isCurrentQuery(this, session, generation, source)) return;
        await restoreCache();
        if (!isCurrentQuery(this, session, generation, source) ||
            _data != null ||
            _phase != QueryPhase.idle) {
          return;
        }
      }
      // A failed preload has no cached payload. One read-only request exposes
      // auth/failure state instead of leaving a permanent, misleading idle card.
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
    if (_phase != QueryPhase.needLogin) _phase = QueryPhase.loaded;
  }

  @override
  void clearCache() {
    _prepared = false;
    _data = null;
    _phase = QueryPhase.idle;
    _error = null;
  }

  @override
  void onConfigurationRequired() => _phase = QueryPhase.needConfiguration;

  Future<void> _load({bool configure = false, bool interactive = true}) async {
    if (_phase == QueryPhase.loading) return;
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final source = CapabilitySourceScope.maybeOf(context)?.source;
    setState(() => _phase = QueryPhase.loading);
    final result = await runDecoded<NoticeList>(
      context,
      session,
      'notice.list',
      interactive: interactive,
      params: {if (configure) 'configure': true},
      decode: noticeListFromDynamic,
    );
    if (!isCurrentQuery(this, session, generation, source)) return;
    setState(() {
      _phase = result.needConfiguration
          ? QueryPhase.needConfiguration
          : result.needLogin
          ? QueryPhase.needLogin
          : result.data == null
          ? QueryPhase.error
          : QueryPhase.loaded;
      _error = result.error;
      if (result.data != null) _data = result.data;
    });
    if (result.data != null) await restoreCache();
  }

  Future<void> _login() async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final source = CapabilitySourceScope.maybeOf(context)?.source;
    if (await promptVisibleLogin(context, session, capability: 'notice.list') &&
        isCurrentQuery(this, session, generation, source)) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final refresh = SectionRefreshButton(
      onPressed: _phase == QueryPhase.loading ? null : _load,
    );
    if (_data != null) {
      return withCacheTime(
        NoticeCard(
          _data!,
          trailing: refresh,
          statusSummary: _phase == QueryPhase.needLogin
              ? querySummary(context, _phase)
              : null,
          status: _phase == QueryPhase.needLogin
              ? QueryPhaseBody(phase: _phase, error: _error, onLogin: _login)
              : null,
        ),
      );
    }
    return SectionCard(
      title: l10n.homeNoticeTitle,
      trailing: refresh,
      summary:
          querySummary(context, _phase) ?? Text(l10n.homeNoticeUnavailable),
      child: QueryPhaseBody(
        phase: _phase,
        error: _error,
        onLogin: _login,
        onConfigure: () => _load(configure: true),
      ),
    );
  }
}
