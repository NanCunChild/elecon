/// Native campus-card balance, ephemeral QR and transaction pages. Shared lifecycle lives in query_section.dart.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;
import 'package:elecon_contract/card_qr.dart';

import 'package:flutter/material.dart';

import '../../core/card_spending.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import '../../session/session_scope.dart';
import 'display_date.dart';
import 'card_layout.dart';
import 'card_spending_view.dart';
import 'models.dart';
import 'schema_decode.dart';
import 'section_card.dart';

import 'query_section.dart';
import 'capability_source.dart';

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
    with CachedQuerySection<CardSection, CardBalance> {
  @override
  void onConfigurationRequired() => _phase = QueryPhase.needConfiguration;

  @override
  String get cacheCapability => 'card.balance';
  @override
  CardBalance? decodeCache(Object? value) => cardBalanceFromDynamic(value);
  @override
  void applyCache(CardBalance data) {
    _data = data;
    _phase = QueryPhase.loaded;
  }

  @override
  void clearCache() {
    _data = null;
    _phase = QueryPhase.idle;
  }

  QueryPhase _phase = QueryPhase.idle;
  CardBalance? _data;
  String? _error;

  Future<void> _load({bool configure = false}) async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final source = CapabilitySourceScope.maybeOf(context)?.source;
    setState(() => _phase = QueryPhase.loading);
    final outcome = await runDecoded<CardBalance>(
      context,
      session,
      'card.balance',
      params: {if (configure) 'configure': true},
      decode: cardBalanceFromDynamic,
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
      targetRef: 'card-session',
      capability: 'card.balance',
    );
    if (!mounted || !isCurrentQuery(this, session, generation, source)) return;
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
            QueryPhaseBody(
              phase: _phase,
              error: _error,
              onLogin: _login,
              onConfigure: () => _load(configure: true),
            )
          else if (data.errorStatus != null)
            Text(_balanceErrorText(data.errorStatus!))
          else ...[
            Text(
              formatQueryMoney(data.balance.amountMinor, data.balance.currency),
              style: Theme.of(
                context,
              ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            if (data.status != null) Text(_cardStatusText(data.status!)),
          ],
        if (!home && (widget.qrEnabled || widget.transactionsEnabled)) ...[
          if (widget.balanceEnabled) const SizedBox(height: 12),
          if (widget.qrEnabled) const CardQrPage(embedded: true),
          if (widget.transactionsEnabled) ...[
            const SizedBox(height: 16),
            const CardTransactionsPage(embedded: true),
          ],
        ],
      ],
    );
    final card = SectionCard(
      title: l10n.homeCardTitle,
      trailing: widget.balanceEnabled
          ? SectionRefreshButton(
              onPressed: _phase == QueryPhase.loading ? null : _load,
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
                  ? formatQueryMoney(
                      data.balance.amountMinor,
                      data.balance.currency,
                    )
                  : _balanceErrorText(data.errorStatus!),
            )
          : widget.qrEnabled
          ? Text(l10n.cardQrHint)
          : widget.transactionsEnabled
          ? Text(l10n.cardTransactions)
          : querySummary(context, _phase),
      child: content,
    );
    return data != null && (!preview || widget.balanceEnabled)
        ? withCacheTime(card)
        : card;
  }
}

/// QR data has no persistent cache and is destroyed on expiry/background/exit.
class CardQrPage extends StatefulWidget {
  const CardQrPage({super.key, this.embedded = false});
  final bool embedded;
  @override
  State<CardQrPage> createState() => _CardQrPageState();
}

class _CardQrPageState extends State<CardQrPage> with WidgetsBindingObserver {
  Uint8List? _image;
  Timer? _expiry;
  ScriptExecutionScope? _execution;
  ScriptRunCancellation? _cancellation;
  String? _purpose;
  QueryPhase _phase = QueryPhase.idle;
  String? _error;
  SessionController? _session;
  CapabilitySource? _source;
  int? _generation, _dataGeneration, _identity, _sourceRevision;
  int _request = 0;
  bool _started = false;
  bool _foreground = true;
  bool _routeVisible = true;
  bool _revealed = false;

  bool get _sameOwner =>
      _session?.identityRevision == _identity &&
      _session?.trustedScriptSourceRevision == _sourceRevision &&
      _session?.trustedScriptDataGeneration == _dataGeneration;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = SessionScope.of(context);
    if (!_started) {
      _started = true;
      _session = session;
      _source = CapabilitySourceScope.maybeOf(context)?.source;
      _generation = session.trustedScriptViewGeneration;
      _dataGeneration = session.trustedScriptDataGeneration;
      _identity = session.identityRevision;
      _sourceRevision = session.trustedScriptSourceRevision;
      _routeVisible = ModalRoute.of(context)?.isCurrent ?? true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_load());
      });
    } else if (_source != CapabilitySourceScope.maybeOf(context)?.source ||
        !identical(session, _session) ||
        !_sameOwner) {
      _clear();
    } else {
      final visible = ModalRoute.of(context)?.isCurrent ?? true;
      if (visible != _routeVisible ||
          session.trustedScriptViewGeneration != _generation) {
        _routeVisible = visible;
        _generation = session.trustedScriptViewGeneration;
        _clear();
        if (visible && _foreground) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(_load(automatic: true));
          });
        }
      }
    }
  }

  void _dropImage() {
    _expiry?.cancel();
    if (_image != null) unawaited(MemoryImage(_image!).evict());
    _image = null;
    _purpose = null;
  }

  void _clear({bool resetReveal = true}) {
    if (resetReveal) _revealed = false;
    _request++;
    _cancellation?.cancel();
    _cancellation = null;
    _execution?.removeListener(_executionChanged);
    _execution?.dispose();
    _execution = null;
    _dropImage();
    _phase = QueryPhase.idle;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!mounted) return;
    if (!_foreground) {
      setState(_clear);
    } else if (_routeVisible && _sameOwner) {
      _generation = _session!.trustedScriptViewGeneration;
      unawaited(_load(automatic: true));
    }
  }

  @override
  void dispose() {
    _clear();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  static CardQr? _decodeQr(Object? raw) {
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
  }

  void _executionChanged() {
    if (!mounted || !_foreground || !_routeVisible || !_sameOwner) return;
    final update = _execution?.update;
    if (update == null) return;
    if (update.result == null) {
      setState(() {
        _dropImage();
        _phase = QueryPhase.loading;
        _error = null;
      });
    } else {
      _showOutcome(decodeCapabilityRun(update.result!, 'card.qr', _decodeQr));
    }
  }

  Future<void> _load({bool configure = false, bool automatic = false}) async {
    final session = _session!;
    if (!_foreground ||
        !_routeVisible ||
        !_sameOwner ||
        !isCurrentQuery(this, session, _generation!, _source)) {
      return;
    }
    _clear(resetReveal: false);
    final request = _request;
    setState(() {
      _phase = QueryPhase.loading;
      _error = null;
    });
    final scope = await session.openScriptExecutionScope(
      'card.qr',
      packageId: _source?.packageId,
      expectedDigest: _source?.digest,
    );
    if (!mounted || request != _request || !_foreground || !_sameOwner) {
      scope?.dispose();
      return;
    }
    if (scope != null) {
      _execution = scope;
      scope.addListener(_executionChanged);
      await scope.run(
        params: {if (configure) 'configure': true},
        interactive: !automatic,
      );
      return;
    }
    final cancellation = _cancellation = ScriptRunCancellation();
    final outcome = await runDecoded<CardQr>(
      context,
      session,
      'card.qr',
      interactive: !automatic,
      cancellation: cancellation,
      params: {if (configure) 'configure': true},
      decode: _decodeQr,
    );
    if (!mounted ||
        request != _request ||
        !_foreground ||
        !_sameOwner ||
        !isCurrentQuery(this, session, _generation!, _source)) {
      return;
    }
    _showOutcome(outcome);
  }

  void _showOutcome(QueryOutcome<CardQr> outcome) {
    try {
      if (outcome.data == null) {
        setState(() {
          _phase = outcome.needConfiguration
              ? QueryPhase.needConfiguration
              : outcome.needLogin
              ? QueryPhase.needLogin
              : QueryPhase.error;
          _error = _execution == null
              ? outcome.error
              : AppLocalizations.of(context).campusLoadFailed;
        });
        return;
      }
      final data = outcome.data!;
      final issued = DateTime.parse(data.issuedAt),
          expires = DateTime.parse(data.expiresAt),
          now = DateTime.now();
      if (!expires.isAfter(issued) ||
          !expires.isAfter(now.add(const Duration(seconds: 2))) ||
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
        _phase = QueryPhase.loaded;
      });
      // Each bounded call obtains a fresh image before the previous image's
      // display deadline. No timer or image survives a hidden page.
      final lifetime = remaining < const Duration(seconds: 60)
          ? remaining
          : const Duration(seconds: 60);
      _expiry = _execution == null
          ? Timer(
              Duration(milliseconds: (lifetime.inMilliseconds * .8).floor()),
              () {
                if (mounted) unawaited(_load(automatic: true));
              },
            )
          : Timer(lifetime, () {
              if (!mounted) return;
              setState(() {
                _dropImage();
                _phase = QueryPhase.idle;
              });
            });
    } catch (_) {
      _execution?.close();
      setState(() {
        _phase = QueryPhase.error;
        _error = AppLocalizations.of(context).cardQrInvalid;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final session = SessionScope.of(context);
    final current =
        _source == CapabilitySourceScope.maybeOf(context)?.source &&
        identical(session, _session) &&
        session.trustedScriptViewGeneration == _generation &&
        session.trustedScriptDataGeneration == _dataGeneration;
    final content = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!current)
          Text(l10n.homeCardDataChanged)
        else ...[
          if (_image != null)
            Center(
              child: SizedBox(
                width: widget.embedded ? 200 : 280,
                height: widget.embedded ? 200 : 280,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ImageFiltered(
                      imageFilter: ImageFilter.blur(
                        sigmaX: _revealed ? 0 : 12,
                        sigmaY: _revealed ? 0 : 12,
                      ),
                      child: ColoredBox(
                        color: Colors.white,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Image.memory(
                            _image!,
                            gaplessPlayback: false,
                            semanticLabel: l10n.cardQrShow,
                            errorBuilder: (_, _, _) => Text(l10n.cardQrInvalid),
                          ),
                        ),
                      ),
                    ),
                    if (!_revealed)
                      Center(
                        child: FilledButton.icon(
                          key: const ValueKey('card-qr-reveal'),
                          onPressed: () => setState(() => _revealed = true),
                          icon: const Icon(Icons.qr_code),
                          label: Text(l10n.cardQrShow),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          if (_purpose != null && !widget.embedded)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_purpose!, textAlign: TextAlign.center),
            ),
          if (_phase == QueryPhase.idle)
            Text(l10n.cardQrExpired, textAlign: TextAlign.center),
          QueryPhaseBody(
            phase: _phase,
            error: _error,
            onConfigure: () => _load(configure: true),
            onLogin: () async {
              _clear();
              final ok = await promptVisibleLogin(
                context,
                session,
                targetRef: 'card-session',
                capability: 'card.qr',
              );
              if (mounted && current && ok) await _load();
            },
          ),
          if (_phase == QueryPhase.error || _phase == QueryPhase.idle)
            Center(
              child: TextButton.icon(
                onPressed: current ? _load : null,
                icon: const Icon(Icons.refresh),
                label: Text(l10n.commonRetry),
              ),
            ),
        ],
      ],
    );
    if (widget.embedded) {
      return Card(
        key: const ValueKey('card-qr-panel'),
        child: SizedBox(
          height: 264,
          child: Center(child: SingleChildScrollView(child: content)),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.cardQrShow),
        actions: [
          SectionRefreshButton(
            onPressed: current && _phase != QueryPhase.loading ? _load : null,
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: content,
        ),
      ),
    );
  }
}

class CardTransactionsPage extends StatefulWidget {
  const CardTransactionsPage({super.key, this.embedded = false});

  final bool embedded;

  @override
  State<CardTransactionsPage> createState() => _CardTransactionsPageState();
}

class _CardTransactionsPageState extends State<CardTransactionsPage> {
  static const _pageSize = 100;
  QueryPhase _phase = QueryPhase.loading;
  CardTransactions? _data;
  final _items = <CardTransactionsItems>[];
  String? _error;
  SessionController? _session;
  CapabilitySource? _source;
  int? _generation;
  int? _dataGeneration;
  int _request = 0;
  int _page = 0;
  int _rangeDays = 30;
  bool _loadingMore = false;
  bool _hasMore = false;
  bool _complete = false;
  bool _stale = false;
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
      _source = CapabilitySourceScope.maybeOf(context)?.source;
      _generation = session.trustedScriptViewGeneration;
      _dataGeneration = session.trustedScriptDataGeneration;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _restoreOrLoad();
      });
    } else if (_source != CapabilitySourceScope.maybeOf(context)?.source ||
        !identical(session, _session) ||
        session.trustedScriptViewGeneration != _generation ||
        session.trustedScriptDataGeneration != _dataGeneration) {
      _request++;
      _data = null;
      _items.clear();
      _error = null;
      _phase = QueryPhase.idle;
    }
  }

  @override
  void dispose() {
    _request++;
    super.dispose();
  }

  Map<String, dynamic> _params(int page) => {
    'from': formatLocalDate(_from),
    'to': formatLocalDate(_to),
    'page': page,
    'size': _pageSize,
  };

  Future<void> _restoreOrLoad() async {
    final session = _session!;
    final request = _request;
    final queries = CapabilityQueries(session, source: _source);
    try {
      final latest = await queries.latestCachedCapability('card.transactions');
      if (!mounted ||
          request != _request ||
          !isCurrentQuery(this, session, _generation!, _source) ||
          session.trustedScriptDataGeneration != _dataGeneration) {
        return;
      }
      final params = latest?.params;
      final from = DateTime.tryParse(params?['from']?.toString() ?? '');
      final to = DateTime.tryParse(params?['to']?.toString() ?? '');
      final days = from == null || to == null
          ? null
          : to.difference(from).inDays + 1;
      if (params?['size'] == _pageSize && [7, 30, 90].contains(days)) {
        _to = to!;
        _rangeDays = days!;
        // A cached page N cannot establish completeness without pages 1..N-1.
        final lastPage = (params?['page'] as int? ?? 1).clamp(1, 100);
        for (var page = 1; page <= lastPage; page++) {
          final cached = await queries.cachedCapability(
            'card.transactions',
            params: _params(page),
          );
          if (!mounted ||
              request != _request ||
              !isCurrentQuery(this, session, _generation!, _source) ||
              session.trustedScriptDataGeneration != _dataGeneration) {
            return;
          }
          final data = cached == null
              ? null
              : cardTransactionsFromDynamic(cached.data);
          if (data == null || (data.page != null && data.page != page)) break;
          _acceptPage(data, page, more: page > 1, fetchedAt: cached!.fetchedAt);
          _stale = _stale || cached.isStale;
          if (_complete) break;
        }
        if (_data != null) {
          setState(() => _phase = QueryPhase.loaded);
          return;
        }
      }
    } catch (_) {
      // A failed cache read falls back to one foreground request.
    }
    if (mounted && request == _request) await _load();
  }

  void _acceptPage(
    CardTransactions data,
    int page, {
    required bool more,
    DateTime? fetchedAt,
  }) {
    if (!more) {
      _items.clear();
      _fetchedAt = fetchedAt ?? DateTime.now();
      _stale = false;
      _snapshotAt = data.snapshotAt;
    }
    _phase = QueryPhase.loaded;
    _data = data;
    _page = page;
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
    final total = data.total;
    _complete =
        data.hasNext != true &&
        data.cursor == null &&
        (total == null || _items.length >= total) &&
        (data.hasNext == false || (total != null && _items.length >= total));
    _hasMore =
        !_complete &&
        data.items.isNotEmpty &&
        (!more || _items.length > previousCount) &&
        data.cursor == null &&
        (data.hasNext == true ||
            (total != null && _items.length < total) ||
            data.items.length >= _pageSize);
  }

  Future<void> _load({bool more = false, bool configure = false}) async {
    final session = _session!;
    if (!isCurrentQuery(this, session, _generation!, _source) ||
        session.trustedScriptDataGeneration != _dataGeneration) {
      return;
    }
    if (more && (_loadingMore || !_hasMore)) return;
    final request = ++_request;
    final nextPage = more ? _page + 1 : 1;
    setState(() {
      _error = null;
      _loginRequired = false;
      _loadingMore = more;
      if (!more) {
        _phase = QueryPhase.loading;
      }
    });
    final outcome = await runDecoded<CardTransactions>(
      context,
      session,
      'card.transactions',
      params: {..._params(nextPage), if (configure) 'configure': true},
      decode: cardTransactionsFromDynamic,
    );
    if (!mounted ||
        request != _request ||
        !isCurrentQuery(this, session, _generation!, _source) ||
        session.trustedScriptDataGeneration != _dataGeneration) {
      return;
    }
    final l10n = AppLocalizations.of(context);
    setState(() {
      _loadingMore = false;
      if (outcome.needConfiguration) {
        _phase = QueryPhase.needConfiguration;
      } else if (outcome.needLogin) {
        _loginRequired = true;
        _phase = _data == null ? QueryPhase.needLogin : QueryPhase.loaded;
      } else if (outcome.error != null ||
          outcome.data == null ||
          (outcome.data!.page != null && outcome.data!.page != nextPage)) {
        _phase = _data == null ? QueryPhase.error : QueryPhase.loaded;
        _error = outcome.error ?? l10n.campusLoadFailed;
      } else {
        _acceptPage(outcome.data!, nextPage, more: more);
      }
    });
  }

  Future<void> _login() async {
    final session = _session!;
    if (!isCurrentQuery(this, session, _generation!, _source) ||
        session.trustedScriptDataGeneration != _dataGeneration) {
      return;
    }
    final ok = await promptVisibleLogin(
      context,
      session,
      targetRef: 'card-session',
      capability: 'card.transactions',
    );
    if (!mounted ||
        !isCurrentQuery(this, session, _generation!, _source) ||
        session.trustedScriptDataGeneration != _dataGeneration) {
      return;
    }
    if (ok) await _load(more: _data != null);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final session = SessionScope.of(context);
    final current =
        _source == CapabilitySourceScope.maybeOf(context)?.source &&
        identical(session, _session) &&
        session.trustedScriptViewGeneration == _generation &&
        session.trustedScriptDataGeneration == _dataGeneration;
    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!current)
            Text(l10n.homeCardDataChanged)
          else ...[
            if (_data != null)
              CardSpendingView(
                summary: CardSpendingSummary.fromTransactions(
                  _items,
                  from: _from,
                  to: _to,
                ),
                partial: !_complete,
                onOpen: () =>
                    openCapabilityPage(context, const CardTransactionsPage()),
              ),
            if (_phase != QueryPhase.loaded)
              QueryPhaseBody(
                phase: _phase,
                error: _error,
                onLogin: _login,
                onConfigure: () => _load(configure: true),
              ),
            if (_data != null && _items.isEmpty)
              Text(l10n.cardSpendingNoRecords),
            if (_fetchedAt != null)
              Text(
                _stale
                    ? l10n.homeDataStaleAt(formatUpdateTime(_fetchedAt!, l10n))
                    : l10n.homeDataUpdatedAt(
                        formatUpdateTime(_fetchedAt!, l10n),
                      ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: () =>
                    openCapabilityPage(context, const CardTransactionsPage()),
                icon: const Icon(Icons.receipt_long_outlined),
                label: Text(l10n.cardTransactions),
              ),
            ),
          ],
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.cardTransactions),
        actions: [
          SectionRefreshButton(
            onPressed: current && _phase != QueryPhase.loading && !_loadingMore
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
                                _data = null;
                                _items.clear();
                                _fetchedAt = null;
                                _snapshotAt = null;
                                _page = 0;
                                _hasMore = false;
                                _complete = false;
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
                  if (_phase == QueryPhase.loading)
                    const Center(child: CircularProgressIndicator())
                  else if (_phase == QueryPhase.needLogin || _loginRequired)
                    Center(
                      child: FilledButton.icon(
                        onPressed: _login,
                        icon: const Icon(Icons.login),
                        label: Text(l10n.cardTransactionsLogin),
                      ),
                    ),
                  if (_phase == QueryPhase.needConfiguration)
                    QueryPhaseBody(
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
                  if (_data != null) ...[
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
                          (_stale
                              ? l10n.homeDataStaleAt
                              : l10n.homeDataUpdatedAt)(
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
                    formatQueryTimestamp(item.time),
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
