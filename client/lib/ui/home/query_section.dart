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
import 'section_card.dart';
import 'capability_source.dart';
import '../login/script_login_page.dart';

/// 一次能力取数 + 解码的归一化结果。
class QueryOutcome<T> {
  const QueryOutcome({
    this.data,
    this.needLogin = false,
    this.error,
    this.reason,
  });

  bool get needConfiguration => reason == 'configuration_required';

  final T? data;
  final bool needLogin;
  final String? error;
  final String? reason;
}

/// 跑能力 → 解码。auth 失败归为 [needLogin]（引导可见登录后重试），不外泄凭证/原因语义。
Future<QueryOutcome<T>> runOnceDecoded<T>(
  SessionController session,
  String capability, {
  Map<String, dynamic>? params,
  bool interactive = true,
  CapabilitySource? source,
  required T? Function(Object?) decode,
}) async {
  final dataGeneration = session.trustedScriptDataGeneration;
  final run = await CapabilityQueries(
    session,
    source: source,
  ).runCapability(capability, params: params, interactive: interactive);
  if (dataGeneration != session.trustedScriptDataGeneration) {
    return const QueryOutcome(reason: 'script_cancelled');
  }
  if (!run.ok) {
    if (run.reason == 'configuration_required') {
      return const QueryOutcome(reason: 'configuration_required');
    }
    if (run.failureKind == CapabilityFailureKind.auth ||
        run.reason == 'authentication_required') {
      return const QueryOutcome(needLogin: true);
    }
    final reason = run.reason?.trim();
    final kind = run.failureKind?.name ?? 'unknown';
    return QueryOutcome(
      reason: reason,
      error: reason == null || reason.isEmpty
          ? '$capability 失败（$kind）'
          : '$capability 失败（$kind）：$reason',
    );
  }
  final data = decode(run.data);
  if (data == null) return QueryOutcome(error: '$capability 产出无法解码');
  return QueryOutcome(data: data);
}

Future<QueryOutcome<T>> runDecoded<T>(
  BuildContext context,
  SessionController session,
  String capability, {
  Map<String, dynamic>? params,
  bool interactive = true,
  required T? Function(Object?) decode,
}) async {
  final first = await runOnceDecoded(
    session,
    source: CapabilitySourceScope.maybeOf(context)?.source,
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
    if (message != null) {
      return QueryOutcome(error: message, reason: first.reason);
    }
  }
  return first;
}

/// 引导当前会话学校的可见登录；成功返回 true。凭证收割在核心（红线 #1）。
Future<bool> promptVisibleLogin(
  BuildContext context,
  SessionController session, {
  String? targetRef,
  String? capability,
}) async {
  final school = session.selectedSchool;
  if (school == null) return false;
  final source = CapabilitySourceScope.maybeOf(context)?.source;
  if (capability != null && school.adapterId.startsWith('script:')) {
    final registry = await session.scriptRegistry;
    final package = source == null
        ? registry.provider(school.id, capability)
        : registry.find(source.packageId)?.package;
    final dependency = package?.manifest
        .capability(capability)
        ?.appTunnelAccountId;
    if (context.mounted &&
        session.selectedSchool?.id == school.id &&
        package != null &&
        (source == null || package.digest == source.digest) &&
        dependency != null) {
      final target = package.manifest.accounts.firstWhere(
        (a) => a.id == dependency,
      );
      if (!session.hasDeclaredTunnelConfiguration(target.appTunnel!)) {
        final result = await Navigator.of(context).push<WebViewLoginResult>(
          MaterialPageRoute(
            builder: (_) => ScriptLoginPage(
              session: session,
              school: school,
              package: package,
              accountId: target.id,
            ),
          ),
        );
        return result?.status == WebViewLoginStatus.success;
      }
    }
  }
  if (!context.mounted) return false;
  if (source != null) {
    final installation = (await session.scriptRegistry).find(source.packageId);
    final package = installation?.package;
    if (!context.mounted ||
        installation?.enabled != true ||
        package == null ||
        package.digest != source.digest ||
        package.requiresUpdate) {
      return false;
    }
    final account = package.manifest.accounts
        .where(
          (a) =>
              a.loginCapability != null &&
              (capability == null || a.capabilities.contains(capability)),
        )
        .firstOrNull;
    if (account == null) return false;
    final result = await Navigator.of(context).push<WebViewLoginResult>(
      MaterialPageRoute(
        builder: (_) => ScriptLoginPage(
          session: session,
          school: school,
          package: package,
          accountId: account.id,
        ),
      ),
    );
    return result?.status == WebViewLoginStatus.success;
  }
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
bool isCurrentSession(State state, SessionController session, int generation) =>
    state.mounted &&
    identical(SessionScope.of(state.context), session) &&
    session.trustedScriptViewGeneration == generation;

/// Source changes can happen without replacing the session (e.g. reused widgets).
bool isCurrentQuery(
  State state,
  SessionController session,
  int generation,
  CapabilitySource? source,
) =>
    isCurrentSession(state, session, generation) &&
    CapabilitySourceScope.maybeOf(state.context)?.source == source;

enum QueryPhase { idle, loading, loaded, needLogin, needConfiguration, error }

/// ADR-038: restore validated current-school data independently of widget life.
/// Background writes notify SessionScope; failed refreshes never replace data.
mixin CachedQuerySection<W extends StatefulWidget, D> on State<W> {
  SessionController? cacheSession;
  CapabilitySource? _cacheSource;
  String? _cacheSchool;
  int? _cacheRevision;
  int? _cacheGeneration;
  int? _cacheDataGeneration;
  int cacheRead = 0;
  DateTime? cacheFetchedAt;
  DateTime? cacheFreshUntil;
  bool cacheStale = false;
  Map<String, dynamic> restoredParams = const {};

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
    final source = CapabilitySourceScope.maybeOf(context)?.source;
    final changed =
        _cacheSource != source ||
        cacheSession != session ||
        _cacheSchool != school ||
        _cacheGeneration != session.trustedScriptViewGeneration ||
        _cacheDataGeneration != session.trustedScriptDataGeneration;
    if (changed) {
      cacheSession = session;
      _cacheSource = source;
      _cacheSchool = school;
      _cacheGeneration = session.trustedScriptViewGeneration;
      _cacheDataGeneration = session.trustedScriptDataGeneration;
      cacheRead++;
      cacheFetchedAt = null;
      cacheFreshUntil = null;
      cacheStale = false;
      restoredParams = const {};
      clearCache();
    }
    if (changed || _cacheRevision != session.homeDataRevision) {
      _cacheRevision = session.homeDataRevision;
      unawaited(restoreCache());
    }
  }

  Future<void> restoreCache() async {
    final session = cacheSession;
    if (session == null) return;
    final read = ++cacheRead;
    final generation = session.trustedScriptViewGeneration;
    final dataGeneration = session.trustedScriptDataGeneration;
    final school = _cacheSchool;
    try {
      final cached = useLatestCache
          ? await CapabilityQueries(
              session,
              source: _cacheSource,
            ).latestCachedCapability(cacheCapability)
          : await CapabilityQueries(
              session,
              source: _cacheSource,
            ).cachedCapability(cacheCapability, params: cacheParams);
      if (!isCurrentSession(this, session, generation) ||
          dataGeneration != session.trustedScriptDataGeneration ||
          read != cacheRead ||
          session.selectedSchool?.id != school) {
        return;
      }
      final decoded = cached == null ? null : decodeCache(cached.data);
      if (decoded == null) {
        final needsConfiguration = await CapabilityQueries(
          session,
          source: _cacheSource,
        ).capabilityNeedsConfiguration(cacheCapability, params: cacheParams);
        if (!isCurrentSession(this, session, generation) ||
            dataGeneration != session.trustedScriptDataGeneration ||
            read != cacheRead) {
          return;
        }
        if (needsConfiguration) {
          setState(onConfigurationRequired);
          return;
        }
        // Revoked, disabled or updated packages cannot leave old cached values
        // visible. A fresh manual result without a cache remains usable.
        if (cacheFetchedAt != null) {
          setState(() {
            cacheFetchedAt = null;
            clearCache();
          });
        }
        return;
      }
      setState(() {
        restoredParams = cached!.params;
        cacheFetchedAt = cached.fetchedAt;
        cacheFreshUntil = cached.freshUntil;
        cacheStale = cached.isStale;
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
    final caption = cacheFetchedAt == null
        ? null
        : (cacheStale
              ? AppLocalizations.of(context).homeDataStaleAt(
                  formatUpdateTime(
                    cacheFetchedAt!,
                    AppLocalizations.of(context),
                  ),
                )
              : AppLocalizations.of(context).homeDataUpdatedAt(
                  formatUpdateTime(
                    cacheFetchedAt!,
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

class QueryPromptCard extends StatelessWidget {
  const QueryPromptCard({
    super.key,
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
class QueryPhaseBody extends StatelessWidget {
  const QueryPhaseBody({
    super.key,
    required this.phase,
    required this.error,
    required this.onLogin,
    this.onConfigure,
  });

  final QueryPhase phase;
  final String? error;
  final VoidCallback onLogin;
  final VoidCallback? onConfigure;

  @override
  Widget build(BuildContext context) {
    switch (phase) {
      case QueryPhase.idle:
      case QueryPhase.loaded:
        return const SizedBox.shrink();
      case QueryPhase.loading:
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
      case QueryPhase.needConfiguration:
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
      case QueryPhase.needLogin:
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
      case QueryPhase.error:
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

String formatQueryDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

Widget? querySummary(BuildContext context, QueryPhase phase) => switch (phase) {
  QueryPhase.loading => Text(AppLocalizations.of(context).homeCardLoading),
  QueryPhase.error => Text(AppLocalizations.of(context).campusLoadFailed),
  QueryPhase.needConfiguration => Text(
    AppLocalizations.of(context).capabilityConfigurationRequired,
  ),
  QueryPhase.needLogin => Text(AppLocalizations.of(context).homeCardNeedsLogin),
  _ => null,
};

String formatQueryMoney(int amountMinor, String currency) {
  final sign = amountMinor < 0 ? '-' : '';
  final absolute = amountMinor.abs();
  final major = absolute ~/ 100;
  final minor = (absolute % 100).toString().padLeft(2, '0');
  final symbol = currency == 'CNY' ? '¥' : '$currency ';
  return '$sign$symbol$major.$minor';
}

String formatQueryTimestamp(String value) {
  final date = DateTime.tryParse(value);
  if (date == null) return value;
  return formatLocalDateTime(date);
}

// ===========================================================================
// 考试 / 图书借阅（用户按需）
