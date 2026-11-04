import 'package:elecon_contract/messages_list.dart';
import 'package:flutter/material.dart';

import '../../core/adapter_service.dart';
import '../../core/scripts/manifest.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import '../scripts/script_input_presenter.dart';
import '../scripts/script_presenter.dart';
import '../settings/script_accounts_page.dart';
import '../home/section_card.dart';
import 'chat_page.dart';

class ForumPage extends StatelessWidget {
  const ForumPage({super.key, required this.session, required this.package});
  final SessionController session;
  final ScriptPackage package;
  @override
  Widget build(BuildContext context) =>
      _ServicePage(session: session, package: package, messages: false);
}

class MessagesPage extends StatelessWidget {
  const MessagesPage({super.key, required this.session, required this.package});
  final SessionController session;
  final ScriptPackage package;
  @override
  Widget build(BuildContext context) =>
      package.manifest.capability('messages.conversations') != null
      ? ChatPage(session: session, package: package)
      : _ServicePage(session: session, package: package, messages: true);
}

class _ServicePage extends StatefulWidget {
  const _ServicePage({
    required this.session,
    required this.package,
    required this.messages,
  });
  final SessionController session;
  final ScriptPackage package;
  final bool messages;
  @override
  State<_ServicePage> createState() => _ServicePageState();
}

class _ServicePageState extends State<_ServicePage>
    with WidgetsBindingObserver {
  Map<String, dynamic>? _account;
  MessagesList? _messages;
  bool _busy = false;
  String? _error;
  int _request = 0;
  ScriptRunCancellation? _cancellation;
  String get _accountCapability =>
      widget.messages ? 'messages.session' : 'forum.session';
  bool get _hasAccount =>
      widget.package.manifest.capability(_accountCapability) != null;
  bool get _loggedIn => _account?['status'] == 'authenticated';
  bool get _tunnelRequired => _error == 'app_tunnel_required';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // This widget only exists while its tab is visible. Discovery itself never
    // executes a script and hidden IndexedStack children cannot log in.
    if (_hasAccount) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _run(_accountCapability, operation: 'status');
      });
    }
  }

  @override
  void didUpdateWidget(covariant _ServicePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.session, widget.session) &&
        oldWidget.package.digest == widget.package.digest &&
        oldWidget.messages == widget.messages) {
      return;
    }
    _request++;
    _cancellation?.cancel();
    _account = null;
    _messages = null;
    _error = null;
    _busy = false;
    if (_hasAccount) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _run(_accountCapability, operation: 'status');
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _request++;
    _cancellation?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.paused &&
        state != AppLifecycleState.detached) {
      return;
    }
    // Frames stop while paused. Clear private state immediately, without waiting
    // for the shell's rebuild to dispose this page. The shell cancels execution.
    _request++;
    _cancellation?.cancel();
    setState(() {
      _account = null;
      _messages = null;
      _error = null;
      _busy = false;
    });
  }

  Future<void> _run(String capability, {String? operation}) async {
    if (_busy) return;
    final request = ++_request;
    final session = widget.session;
    final package = widget.package;
    final generation = session.trustedScriptViewGeneration;
    bool active() =>
        _isCurrent(request, session, package) &&
        generation == session.trustedScriptViewGeneration;
    final cancellation = ScriptRunCancellation();
    _cancellation = cancellation;
    setState(() {
      _busy = true;
      _error = null;
      // Never retain old-account messages across login, logout or failed refresh.
      _messages = null;
      if (operation != null) _account = null;
    });
    try {
      final result =
          await presentScriptInput(
                context,
                package,
                (input) => presentScriptBrowser(
                  context,
                  package,
                  (browser) => session.runTrustedScript(
                    package.manifest.id,
                    capability,
                    expectedDigest: package.digest,
                    params: operation != null
                        ? {'operation': operation}
                        : const {},
                    inputCall: input,
                    browserCall: browser,
                    cancellation: cancellation,
                  ),
                  onCancel: cancellation.cancel,
                ),
                onCancel: cancellation.cancel,
              )
              as CapabilityRun;
      if (!active()) return;
      setState(() {
        if (!result.ok) {
          _error = result.reason ?? 'script_failed';
          if (_error == 'authentication_required' || _tunnelRequired) {
            _account = null;
          }
          return;
        }
        final data = Map<String, dynamic>.from(result.data as Map);
        if (capability == 'messages.list') {
          _messages = MessagesList(
            serviceId: data['serviceId'] as String,
            accountId: data['accountId'] as String,
            accountLabel: data['accountLabel'] as String,
            windowStartedAt: data['windowStartedAt'] as String,
            fetchedAt: data['fetchedAt'] as String,
            coverage: data['coverage'] as String,
            items: [
              for (final raw in data['items'] as List)
                MessagesListItems(
                  id: raw['id'] as String,
                  conversationId: raw['conversationId'] as String,
                  text: raw['text'] as String,
                  kind:
                      package.manifest
                              .capability('messages.list')
                              ?.schemaVersion ==
                          '1.1'
                      ? raw['kind'] as String
                      : 'unknown',
                  senderId: raw['senderId'] as String?,
                  sentAt: raw['sentAt'] as String?,
                  activityId: raw['activityId'] as String?,
                ),
            ],
          );
        } else {
          _account = data;
        }
      });
    } catch (_) {
      if (active()) {
        setState(() => _error = 'script_failed');
      }
    } finally {
      if (identical(_cancellation, cancellation)) _cancellation = null;
      cancellation.dispose();
      if (mounted && request == _request) setState(() => _busy = false);
    }
  }

  bool _isCurrent(
    int request,
    SessionController session,
    ScriptPackage package,
  ) =>
      mounted &&
      request == _request &&
      identical(session, widget.session) &&
      package.digest == widget.package.digest &&
      session.selectedSchool?.id == package.manifest.schoolId;

  Future<void> _openAccounts() async {
    if (_busy) return;
    final request = ++_request;
    final session = widget.session;
    final package = widget.package;
    var schoolChanged = false;
    void watchSchool() {
      schoolChanged |= session.selectedSchool?.id != package.manifest.schoolId;
    }

    session.addListener(watchSchool);
    setState(() => _busy = true);
    try {
      final registry = await session.scriptRegistry;
      final epoch = registry.epoch;
      if (!mounted || !_isCurrent(request, session, package) || schoolChanged) {
        return;
      }
      await Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => const ScriptAccountsPage()),
      );
      if (!_isCurrent(request, session, package) ||
          schoolChanged ||
          registry.epoch != epoch ||
          registry.find(package.manifest.id)?.enabled != true ||
          registry.find(package.manifest.id)?.package.digest !=
              package.digest) {
        return;
      }
      // The user may have signed into the tunnel. Recheck only; connecting the
      // forum remains an explicit action and never replays the previous login.
      setState(() => _busy = false);
      if (_hasAccount) await _run(_accountCapability, operation: 'status');
    } catch (_) {
      if (_isCurrent(request, session, package) && !schoolChanged) {
        setState(() => _error = 'script_failed');
      }
    } finally {
      session.removeListener(watchSchool);
      if (mounted && request == _request) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.messages ? l10n.navMessages : l10n.navForum),
        actions: [
          if (widget.messages)
            SectionRefreshButton(
              onPressed: _busy || (_hasAccount && !_loggedIn)
                  ? null
                  : () => _run('messages.list'),
            ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    widget.package.manifest.name,
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    widget.messages
                        ? l10n.messagesWindowDescription
                        : l10n.forumAccountDescription,
                  ),
                  const SizedBox(height: 16),
                  if (_account != null)
                    Text(
                      _loggedIn
                          ? l10n.communityConnected(
                              _account!['serviceName'] as String,
                              _account!['accountLabel'] as String? ?? '',
                            )
                          : l10n.communitySignedOut,
                    ),
                  if (_hasAccount)
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        FilledButton(
                          onPressed: _busy
                              ? null
                              : _tunnelRequired
                              ? _openAccounts
                              : () => _run(
                                  _accountCapability,
                                  operation: 'login',
                                ),
                          child: Text(l10n.communityConnect),
                        ),
                        if (_loggedIn)
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => _run(
                                    _accountCapability,
                                    operation: 'logout',
                                  ),
                            child: Text(l10n.communityDisconnect),
                          ),
                      ],
                    ),
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: LinearProgressIndicator(),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        _error == 'authentication_required'
                            ? l10n.communityLoginRequired
                            : _tunnelRequired
                            ? l10n.scriptTunnelRequired
                            : _error == 'input_cancelled'
                            ? l10n.scriptsInputCancelled
                            : l10n.communityRequestFailed,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  if (_tunnelRequired)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton(
                        onPressed: _busy ? null : _openAccounts,
                        child: Text(l10n.scriptAccountsTitle),
                      ),
                    ),
                  if (_messages case final messages?) ...[
                    const SizedBox(height: 16),
                    Text(
                      l10n.communityConnected(
                        _account?['serviceName'] as String? ??
                            widget.package.manifest.name,
                        messages.accountLabel,
                      ),
                    ),
                    Text(
                      l10n.messagesWindowTime(
                        messages.windowStartedAt,
                        messages.fetchedAt,
                      ),
                    ),
                    if (messages.items.isEmpty) Text(l10n.messagesWindowEmpty),
                    for (final item in messages.items)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (item.kind == 'activity' ||
                                  item.kind == 'command')
                                Text(
                                  item.kind == 'activity'
                                      ? l10n.messagesKindActivity
                                      : l10n.messagesKindCommand,
                                  style: theme.textTheme.labelMedium,
                                ),
                              Text(item.text),
                              const SizedBox(height: 8),
                              Text(
                                l10n.messagesSource(
                                  item.conversationId,
                                  item.senderId ?? '—',
                                ),
                                style: theme.textTheme.bodySmall,
                              ),
                              if (item.sentAt != null)
                                Text(
                                  item.sentAt!,
                                  style: theme.textTheme.bodySmall,
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
