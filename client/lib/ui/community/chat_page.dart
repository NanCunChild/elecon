import 'dart:math';
import 'dart:async';

import 'package:elecon_contract/messages_conversations.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/adapter_service.dart';
import '../../core/scripts/manifest.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import '../scripts/script_input_presenter.dart';
import '../scripts/script_presenter.dart';
import 'conversation_avatar.dart';

/// Native inbox/chat interaction. Service protocols and entity links stay out.
class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.session, required this.package});
  final SessionController session;
  final ScriptPackage package;
  @override
  State<ChatPage> createState() => _ChatPageState();
}

/// Only the source's known message time belongs in the inbox. A missing or
/// invalid timestamp remains blank; cache retrieval time is never substituted.
class ConversationTimestamp extends StatelessWidget {
  const ConversationTimestamp({super.key, required this.value, this.now});

  final String value;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final time = DateTime.tryParse(value)?.toLocal();
    if (time == null) return const SizedBox.shrink();
    final current = now ?? DateTime.now();
    final locale = Localizations.localeOf(context).toString();
    final compact = DateUtils.isSameDay(time, current)
        ? MaterialLocalizations.of(context).formatTimeOfDay(
            TimeOfDay.fromDateTime(time),
            alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
          )
        : (time.year == current.year
                  ? DateFormat.Md(locale)
                  : DateFormat.yMd(locale))
              .format(time);
    final full = DateFormat.yMd(locale).add_Hm().format(time);
    final label = AppLocalizations.of(context).messagesLastMessageAt(full);
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        excludeSemantics: true,
        child: Text(
          compact,
          maxLines: 1,
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ),
    );
  }
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  final _composer = TextEditingController();
  final _timeline = ScrollController();
  Map<String, dynamic>? _account;
  List<MessagesConversationsItems> _conversations = [];
  MessagesConversationsItems? _conversation;
  final _messages = <String, ArchivedMessage>{};
  final _observed = <String, int>{};
  final _cursors = <String>{};
  bool _busy = false;
  bool _showConversationId = false;
  bool _storageFailed = false;
  bool _localMore = false;
  bool? _remoteMore;
  String? _cursor;
  String? _coverage;
  String? _fetchedAt;
  String? _error;
  String _sendPermission = 'unknown';
  String? _sendPermissionReason;
  final _attempts = <String, ({String text, String status})>{};
  String _query = '';
  int _localLimit = 100;
  int _request = 0;
  late int _generation;
  ScriptRunCancellation? _cancellation;
  bool _paused = false;
  ScriptRunCancellation? _enrichmentCancellation;
  ScriptRequestBudget? _directoryBudget;
  bool get _connected => _account?['status'] == 'authenticated';

  @override
  void initState() {
    super.initState();
    _generation = widget.session.trustedScriptViewGeneration;
    widget.session.addListener(_sessionChanged);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _initialize();
    });
  }

  @override
  void dispose() {
    _cancel();
    widget.session.removeListener(_sessionChanged);
    WidgetsBinding.instance.removeObserver(this);
    _composer.dispose();
    _timeline.dispose();
    super.dispose();
  }

  void _cancel() {
    _request++;
    _cancellation?.cancel();
    _enrichmentCancellation?.cancel();
  }

  void _clearChat() {
    _sendPermission = 'unknown';
    _sendPermissionReason = null;
    _messages.clear();
    _observed.clear();
    _cursors.clear();
    _composer.clear();
    _attempts.clear();
    _cursor = null;
    _remoteMore = null;
    _localMore = false;
    _localLimit = 100;
    _fetchedAt = null;
  }

  void _clearAccount() {
    _account = null;
    _conversations = [];
    _conversation = null;
    _coverage = null;
    _query = '';
    _clearChat();
  }

  void _sessionChanged() {
    if (_generation == widget.session.trustedScriptViewGeneration) return;
    _cancel();
    if (mounted) {
      setState(() {
        _clearAccount();
        _busy = false;
        _error = null;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _paused = true;
      _cancel();
      setState(() {
        _clearAccount();
        _busy = false;
        _error = null;
      });
    } else if (state == AppLifecycleState.resumed && _paused) {
      _paused = false;
      _initialize();
    }
  }

  bool _valid(int request) =>
      mounted &&
      !_paused &&
      request == _request &&
      _generation == widget.session.trustedScriptViewGeneration;

  void _applyArchive(MessageArchiveView view) {
    if (_account?['accountId'] != view.account['accountId'] ||
        _account?['serviceId'] != view.account['serviceId']) {
      _clearAccount();
    }
    _account = view.account;
    _conversations = view.conversations;
    for (final row in view.messages) {
      _messages[row.id] = row;
    }
    _localMore = view.hasMoreLocal;
    if (_conversation != null) {
      _remoteMore = view.hasMoreRemote;
      _cursor = view.nextCursor;
    } else {
      _coverage = view.coverage;
    }
    _fetchedAt = view.fetchedAt;
  }

  Future<void> _loadLocal() async {
    final request = ++_request;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final view = await widget.session.messageArchive(
        widget.package,
        conversationId: _conversation?.conversationId,
        conversationKind: _conversation?.conversationKind,
        limit: _localLimit,
      );
      if (_valid(request) && view != null) setState(() => _applyArchive(view));
    } catch (_) {
      if (_valid(request)) setState(() => _storageFailed = true);
    } finally {
      if (_valid(request)) setState(() => _busy = false);
    }
  }

  Future<void> _initialize() async {
    await _loadLocal();
    if (!mounted || _paused) return;
    final status = await _run('messages.session', {'operation': 'status'});
    if (mounted && status?.ok == true && _connected) await _refresh();
  }

  Map<String, dynamic> get _target => {
    'accountId': _account!['accountId'],
    if (_conversation != null) ...{
      'conversationId': _conversation!.conversationId,
      'conversationKind': _conversation!.conversationKind,
    },
  };

  Future<CapabilityRun?> _run(
    String capability,
    Map<String, dynamic> params,
  ) async {
    if (_busy ||
        _paused ||
        _generation != widget.session.trustedScriptViewGeneration) {
      return null;
    }
    final request = ++_request;
    final cancellation = ScriptRunCancellation();
    _cancellation = cancellation;
    setState(() {
      _busy = true;
      _error = null;
      _storageFailed = false;
      if (capability == 'messages.history') {
        _sendPermission = 'unknown';
        _sendPermissionReason = null;
      }
      if (capability == 'messages.session' && params['operation'] != 'status') {
        _clearAccount();
      }
    });
    try {
      final result =
          await presentScriptInput(
                context,
                widget.package,
                (input) => presentScriptBrowser(
                  context,
                  widget.package,
                  (browser) => widget.session.runTrustedScript(
                    widget.package.manifest.id,
                    capability,
                    params: params,
                    inputCall: input,
                    browserCall: browser,
                    cancellation: cancellation,
                    requestBudget: capability == 'messages.conversations'
                        ? _directoryBudget
                        : null,
                  ),
                  onCancel: cancellation.cancel,
                ),
                onCancel: cancellation.cancel,
              )
              as CapabilityRun;
      if (!_valid(request)) return null;
      if (!result.ok) {
        setState(() {
          _error = result.reason;
          if (capability == 'messages.send') _sendState(params, 'unknown');
          if (result.reason == 'authentication_required') _clearAccount();
        });
        return result;
      }
      MessageArchiveView? local;
      try {
        local = await widget.session.messageArchive(
          widget.package,
          conversationId: _conversation?.conversationId,
          conversationKind: _conversation?.conversationKind,
          limit: _localLimit,
        );
      } catch (_) {
        if (_valid(request)) _storageFailed = true;
      }
      if (!_valid(request)) return null;
      final data = Map<String, dynamic>.from(result.data as Map);
      setState(() {
        if (local != null) _applyArchive(local);
        _storageFailed = _storageFailed || result.localStorageFailed;
        if (capability == 'messages.session') {
          if (data['status'] != 'authenticated') _clearAccount();
          _account = data;
        } else if (capability == 'messages.conversations') {
          final rows = <MessagesConversationsItems>[
            for (final row in data['items'] as List)
              MessagesConversationsItems(
                conversationId: row['conversationId'] as String,
                conversationKind: row['conversationKind'] as String,
                title: row['title'] as String,
                avatarImages:
                    widget.package.manifest
                            .capability(capability)
                            ?.schemaVersion ==
                        '1.3'
                    ? (row['avatarImages'] as List?)?.cast<String>()
                    : null,
                sendPermission:
                    const {'1.2', '1.3'}.contains(
                      widget.package.manifest
                          .capability(capability)
                          ?.schemaVersion,
                    )
                    ? row['sendPermission'] as String?
                    : null,
                sendPermissionReason:
                    const {'1.2', '1.3'}.contains(
                      widget.package.manifest
                          .capability(capability)
                          ?.schemaVersion,
                    )
                    ? row['sendPermissionReason'] as String?
                    : null,
                hasContent:
                    widget.package.manifest
                            .capability(capability)
                            ?.schemaVersion !=
                        '1.0'
                    ? row['hasContent'] as bool?
                    : null,
                lastMessageAt:
                    widget.package.manifest
                            .capability(capability)
                            ?.schemaVersion !=
                        '1.0'
                    ? row['lastMessageAt'] as String?
                    : null,
              ),
          ];
          _conversations = MessageArchiveView.mergeConversations(
            rows,
            _conversations,
            preserveMissing: data['coverage'] == 'partial',
          );
          _coverage = data['coverage'] as String;
        } else if (capability == 'messages.history') {
          if (widget.package.manifest.capability(capability)?.schemaVersion ==
              '1.1') {
            _sendPermission = data['sendPermission'] as String? ?? 'unknown';
            _sendPermissionReason = data['sendPermissionReason'] as String?;
          }
          for (final row in data['items'] as List) {
            final item = ArchivedMessage.fromData(
              Map<String, dynamic>.from(row as Map),
            );
            // A local tombstone survives even when the server repeats an old page.
            if (_messages[item.id]?.recalled != true) _messages[item.id] = item;
          }
          for (final id in (data['recalledIds'] as List).cast<String>()) {
            _messages[id] = ArchivedMessage(id, null, _messages[id]?.sentAt);
          }
          _remoteMore = data['hasMore'] as bool;
          _cursor = data['nextCursor'] as String?;
          if (_cursor != null &&
              params['cursor'] != null &&
              _cursors.contains(_cursor)) {
            _remoteMore = false;
            _cursor = null;
            _error = 'source_response_invalid';
          }
          if (params['cursor'] case final String cursor) _cursors.add(cursor);
        } else if (capability == 'messages.send') {
          _sendState(params, data['status'] as String);
          if (data['status'] == 'rejected') _sendPermission = 'unknown';
          if (data['status'] == 'sent') {
            final item = ArchivedMessage.fromData({
              'id': data['messageId'],
              'text': params['text'],
              'kind': 'text',
              'direction': 'outgoing',
              if (data['sentAt'] != null) 'sentAt': data['sentAt'],
            });
            if (_messages[item.id]?.recalled != true) _messages[item.id] = item;
            _attempts.remove(params['clientId']);
          }
        }
        if (data['fetchedAt'] is String) {
          _fetchedAt = data['fetchedAt'] as String;
        }
      });
      return result;
    } catch (_) {
      if (_valid(request)) {
        setState(() {
          _error = 'script_failed';
          if (capability == 'messages.send') _sendState(params, 'unknown');
        });
      }
      return null;
    } finally {
      if (identical(_cancellation, cancellation)) _cancellation = null;
      cancellation.dispose();
      if (_valid(request)) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    if (!_connected) return;
    if (_conversation == null) {
      _enrichmentCancellation?.cancel();
      _directoryBudget = ScriptRequestBudget();
      final result = await _run('messages.conversations', _target);
      if (result?.ok == true && mounted && !_paused && _conversation == null) {
        unawaited(_enrichConversations());
      }
    } else {
      _cursors.clear();
      await _run('messages.history', _target);
    }
  }

  Future<void> _enrichConversations() async {
    if (widget.package.manifest.capability('messages.enrich') == null) return;
    final request = _request;
    final account = _account?['accountId'];
    final budget = _directoryBudget;
    final cancellation = ScriptRunCancellation();
    _enrichmentCancellation?.cancel();
    _enrichmentCancellation = cancellation;
    bool active() =>
        _valid(request) &&
        !cancellation.isCancelled &&
        _conversation == null &&
        _account?['accountId'] == account;
    final rows = _conversations.take(64).toList();
    try {
      await WidgetsBinding.instance.endOfFrame;
      for (var offset = 0; offset < rows.length; offset += 8) {
        if (!active() || budget == null || budget.remaining < 8) return;
        final result = await widget.session.runTrustedScript(
          widget.package.manifest.id,
          'messages.enrich',
          expectedDigest: widget.package.digest,
          params: {
            'accountId': account,
            'items': [
              for (final row in rows.skip(offset).take(8))
                {
                  'conversationId': row.conversationId,
                  'conversationKind': row.conversationKind,
                },
            ],
          },
          cancellation: cancellation,
          requestBudget: budget,
        );
        if (!active()) return;
        if (!result.ok || result.localStorageFailed) {
          _showEnrichmentFailure(result);
          return;
        }
        final MessageArchiveView? local;
        try {
          local = await widget.session.messageArchive(widget.package);
        } catch (_) {
          if (active()) setState(() => _storageFailed = true);
          return;
        }
        if (!active()) return;
        if (local case final view?) setState(() => _applyArchive(view));
      }
    } catch (_) {
      if (active()) setState(() => _error = 'script_failed');
    } finally {
      if (identical(_enrichmentCancellation, cancellation)) {
        _enrichmentCancellation = null;
      }
      cancellation.dispose();
    }
  }

  void _showEnrichmentFailure(CapabilityRun result) {
    // Only ordinary network failures are optional. Host limits, revocation and
    // invalid results keep their classification and never authorize a retry.
    if (!result.localStorageFailed &&
        const {
          'fetch_failed',
          'http_failed',
          'connection_failed',
          'request_timeout',
        }.contains(result.reason)) {
      return;
    }
    setState(() {
      if (result.reason == 'authentication_required') _clearAccount();
      if (result.localStorageFailed ||
          const {
            'credential_persist_failed',
            'credential_storage_unavailable',
            'protected_store_unavailable',
            'account_storage_failed',
            'account_storage_invalid',
          }.contains(result.reason)) {
        _storageFailed = true;
      } else if (!result.ok) {
        _error = result.reason;
      }
    });
  }

  Future<void> _open(MessagesConversationsItems conversation) async {
    _cancel();
    setState(() {
      _clearChat();
      _conversation = conversation;
      _error = null;
      _busy = false;
    });
    await _loadLocal();
    _showLatest();
    if (mounted && _conversation == conversation && !_paused) await _refresh();
  }

  void _back() {
    _cancel();
    setState(() {
      _clearChat();
      _conversation = null;
      _busy = false;
      _error = null;
    });
    _loadLocal();
  }

  Future<void> _older() async {
    if (_localMore) {
      _localLimit = min(2000, _localLimit + 100);
      await _loadLocal();
    } else if (_remoteMore == true && _cursor != null) {
      await _run('messages.history', {..._target, 'cursor': _cursor});
    }
  }

  Future<void> _send() async {
    final text = _composer.text;
    if (_busy ||
        _sendPermission != 'allowed' ||
        text.trim().isEmpty ||
        text.length > 4000) {
      return;
    }
    // 61-bit decimal request ID, kept exact throughout protobuf and confirmation.
    final clientId =
        ((BigInt.from(DateTime.now().millisecondsSinceEpoch) << 20) |
                BigInt.from(Random.secure().nextInt(1 << 20)))
            .toString();
    final conversation = _conversation;
    setState(() {
      _attempts[clientId] = (text: text, status: 'sending');
      _composer.clear();
    });
    _showLatest();
    final result = await _run('messages.send', {
      ..._target,
      'clientId': clientId,
      'text': text,
    });
    if (mounted &&
        _conversation == conversation &&
        result?.ok == true &&
        (result!.data as Map)['status'] == 'sent') {
      await _refresh();
    }
  }

  String _time(String value) {
    final time = DateTime.tryParse(value)?.toLocal();
    return time == null
        ? value
        : DateFormat.yMd(
            Localizations.localeOf(context).toString(),
          ).add_Hm().format(time);
  }

  void _sendState(Map<String, dynamic> params, String status) {
    final id = params['clientId'] as String;
    final previous = _attempts[id];
    if (previous != null) _attempts[id] = (text: previous.text, status: status);
  }

  void _showLatest() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted && _timeline.hasClients) _timeline.jumpTo(0);
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final selected = _conversation;
    final records = _messages.values.toList();
    int order(ArchivedMessage item) =>
        DateTime.tryParse(item.sentAt ?? '')?.millisecondsSinceEpoch ??
        _observed.putIfAbsent(
          item.id,
          () => DateTime.now().millisecondsSinceEpoch,
        );
    records.sort((a, b) {
      final byTime = order(a).compareTo(order(b));
      return byTime != 0
          ? byTime
          : a.id.length.compareTo(b.id.length) != 0
          ? a.id.length.compareTo(b.id.length)
          : a.id.compareTo(b.id);
    });
    final filtered = _conversations
        .where(
          (row) => '${row.title} ${row.conversationId}'.toLowerCase().contains(
            _query.toLowerCase(),
          ),
        )
        .toList();
    final canHistory =
        widget.package.manifest.capability('messages.history') != null;
    return PopScope(
      canPop: selected == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && selected != null) _back();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: selected == null ? null : BackButton(onPressed: _back),
          title: selected == null
              ? Text(l10n.navMessages)
              : Row(
                  children: [
                    ConversationAvatar(
                      kind: selected.conversationKind,
                      images: selected.avatarImages,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        selected.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
          actions: [
            if (selected != null)
              IconButton(
                tooltip: l10n.messagesConversationInfo,
                onPressed: () =>
                    setState(() => _showConversationId = !_showConversationId),
                icon: const Icon(Icons.info_outline),
              ),
            IconButton(
              tooltip: l10n.messagesRefresh,
              onPressed: _busy || !_connected ? null : _refresh,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 800),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.package.manifest.name,
                          style: theme.textTheme.labelMedium,
                        ),
                        if (selected != null && _showConversationId)
                          SelectableText(
                            l10n.messagesConversationId(
                              selected.conversationId,
                            ),
                            style: theme.textTheme.bodySmall,
                          ),
                        if (_connected)
                          Text(
                            l10n.communityConnected(
                              _account!['serviceName'] as String? ?? '',
                              _account!['accountLabel'] as String? ?? '',
                            ),
                            style: theme.textTheme.bodySmall,
                          ),
                        if (selected == null)
                          Wrap(
                            spacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              if (!_connected)
                                FilledButton(
                                  onPressed: _busy
                                      ? null
                                      : () async {
                                          final result = await _run(
                                            'messages.session',
                                            {'operation': 'login'},
                                          );
                                          if (mounted &&
                                              result?.ok == true &&
                                              _connected) {
                                            await _refresh();
                                          }
                                        },
                                  child: Text(l10n.communityConnect),
                                ),
                              if (_connected)
                                TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _run('messages.session', {
                                          'operation': 'logout',
                                        }),
                                  child: Text(l10n.communityDisconnect),
                                ),
                            ],
                          ),
                        if (_fetchedAt != null)
                          Text(
                            l10n.messagesSavedAt(_time(_fetchedAt!)),
                            style: theme.textTheme.bodySmall,
                          ),
                        if (_storageFailed)
                          Text(
                            l10n.messagesStorageFailed,
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        if (_error != null)
                          Text(
                            _error == 'authentication_required'
                                ? l10n.communityLoginRequired
                                : _error == 'input_cancelled'
                                ? l10n.scriptsInputCancelled
                                : l10n.messagesRefreshFailed,
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                      ],
                    ),
                  ),
                  if (_busy) const LinearProgressIndicator(),
                  if (selected == null) ...[
                    if (_connected)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: TextField(
                          decoration: InputDecoration(
                            labelText: l10n.messagesSearch,
                            prefixIcon: const Icon(Icons.search),
                          ),
                          onChanged: (value) => setState(() => _query = value),
                        ),
                      ),
                    if (_coverage == 'partial')
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(l10n.messagesPartial),
                      ),
                    Expanded(
                      child: filtered.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text(
                                  !_connected
                                      ? l10n.communitySignedOut
                                      : _busy
                                      ? l10n.messagesLoading
                                      : _query.isNotEmpty
                                      ? l10n.messagesNoMatches
                                      : l10n.messagesConversationsEmpty,
                                ),
                              ),
                            )
                          : ListView.builder(
                              itemCount: filtered.length,
                              itemBuilder: (context, index) {
                                final row = filtered[index];
                                return ListTile(
                                  leading: ConversationAvatar(
                                    kind: row.conversationKind,
                                    images: row.avatarImages,
                                  ),
                                  title: Text(
                                    row.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    row.conversationKind == 'group'
                                        ? l10n.messagesGroup
                                        : l10n.messagesDirect,
                                  ),
                                  trailing: row.lastMessageAt == null
                                      ? null
                                      : ConversationTimestamp(
                                          value: row.lastMessageAt!,
                                        ),
                                  onTap: _busy || !canHistory
                                      ? null
                                      : () => _open(row),
                                );
                              },
                            ),
                    ),
                  ] else ...[
                    Expanded(
                      child:
                          records.isEmpty &&
                              !_busy &&
                              _attempts.isEmpty &&
                              _remoteMore != true
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text(l10n.messagesHistoryEmpty),
                              ),
                            )
                          : ListView(
                              controller: _timeline,
                              padding: const EdgeInsets.all(16),
                              reverse: true,
                              children: [
                                for (final attempt
                                    in _attempts.values.toList().reversed)
                                  _bubble(
                                    context,
                                    attempt.text,
                                    true,
                                    attempt.status == 'sending'
                                        ? l10n.messagesSending
                                        : attempt.status == 'rejected'
                                        ? l10n.messagesRejected
                                        : l10n.messagesSendUnknown,
                                  ),
                                for (final row in records.reversed)
                                  _bubble(
                                    context,
                                    row.recalled
                                        ? l10n.messagesRecalled
                                        : row.content!.text,
                                    row.content?.direction == 'outgoing',
                                    [
                                      if (row.content?.direction !=
                                              'outgoing' &&
                                          row.content != null)
                                        row.content!.senderLabel ??
                                            row.content!.senderId ??
                                            l10n.messagesUnknownSender,
                                      if (row.sentAt != null)
                                        _time(row.sentAt!),
                                    ].join(' · '),
                                    kind: row.content?.kind,
                                  ),
                                if (_localMore || _remoteMore == true)
                                  Center(
                                    child: TextButton(
                                      onPressed: _busy ? null : _older,
                                      child: Text(
                                        _localMore
                                            ? l10n.messagesMoreLocal
                                            : l10n.messagesMoreHistory,
                                      ),
                                    ),
                                  ),
                                if (_remoteMore == false)
                                  Text(
                                    l10n.messagesHistoryEnd,
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.bodySmall,
                                  ),
                              ],
                            ),
                    ),
                    if (_connected &&
                        widget.package.manifest.capability('messages.send') !=
                            null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _composer,
                                enabled: !_busy && _sendPermission == 'allowed',
                                minLines: 1,
                                maxLines: 4,
                                maxLength: 4000,
                                decoration: InputDecoration(
                                  hintText: l10n.messagesCompose,
                                  helperMaxLines: 3,
                                  helperText:
                                      _busy || _sendPermission == 'allowed'
                                      ? null
                                      : _sendPermission == 'muted'
                                      ? (_sendPermissionReason ==
                                                'group_disabled'
                                            ? l10n.messagesGroupDisabled
                                            : l10n.messagesCannotSendMuted)
                                      : l10n.messagesPermissionUnknown,
                                  border: const OutlineInputBorder(),
                                ),
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Padding(
                              padding: const EdgeInsets.only(bottom: 24),
                              child: IconButton.filled(
                                tooltip: l10n.messagesSend,
                                onPressed:
                                    _busy ||
                                        _sendPermission != 'allowed' ||
                                        _composer.text.trim().isEmpty
                                    ? null
                                    : _send,
                                icon: const Icon(Icons.send_outlined),
                              ),
                            ),
                          ],
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

  Widget _bubble(
    BuildContext context,
    String text,
    bool outgoing,
    String caption, {
    String? kind,
  }) {
    final theme = Theme.of(context);
    return Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(12),
        constraints: const BoxConstraints(maxWidth: 600),
        decoration: BoxDecoration(
          color: outgoing
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (kind == 'activity' || kind == 'command') ...[
              Text(
                kind == 'activity'
                    ? AppLocalizations.of(context).messagesKindActivity
                    : AppLocalizations.of(context).messagesKindCommand,
                style: theme.textTheme.labelMedium,
              ),
              const SizedBox(height: 4),
            ],
            SelectableText(
              text,
              style: TextStyle(
                color: outgoing
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.onSurface,
              ),
            ),
            if (caption.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(caption, style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}
