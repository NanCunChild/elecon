import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import '../../session/session_scope.dart';
import 'capability_source.dart';
import 'display_date.dart';
import 'models.dart';
import 'notice_detail_page.dart';

/// A bounded preview of the same notice snapshot used by the full list.
/// Rotation never queries a provider or changes the card's bound source.
class NoticeSummary extends StatefulWidget {
  const NoticeSummary({super.key, required this.items});

  final List<NoticeListItems> items;

  @override
  State<NoticeSummary> createState() => _NoticeSummaryState();
}

class _NoticeSummaryState extends State<NoticeSummary>
    with WidgetsBindingObserver {
  Timer? _timer;
  ScrollPosition? _scroll;
  Object? _identity;
  int _index = 0;
  bool _enabled = false;
  bool _foreground = true;
  bool _visible = false;
  bool _interacted = false;
  bool _checkScheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = context
        .dependOnInheritedWidgetOfExactType<SessionScope>()
        ?.notifier;
    final identity = (
      session,
      session?.selectedSchool?.id,
      session?.trustedScriptViewGeneration,
      session?.trustedScriptDataGeneration,
      CapabilitySourceScope.maybeOf(context)?.source,
    );
    if (_identity != identity) {
      _identity = identity;
      _index = 0;
      _interacted = false;
      _timer?.cancel();
      _timer = null;
    }
    _enabled =
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context) &&
        !MediaQuery.accessibleNavigationOf(context) &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    final scroll = Scrollable.maybeOf(context)?.position;
    if (_scroll != scroll) {
      _scroll?.removeListener(_scheduleVisibilityCheck);
      _scroll = scroll;
      _scroll?.addListener(_scheduleVisibilityCheck);
    }
    _syncTimer();
    _scheduleVisibilityCheck();
  }

  @override
  void didUpdateWidget(covariant NoticeSummary oldWidget) {
    super.didUpdateWidget(oldWidget);
    final id = oldWidget.items.isEmpty ? null : oldWidget.items[_index].id;
    final next = widget.items.indexWhere((item) => item.id == id);
    _index = next < 0 ? 0 : next;
    _syncTimer();
    _scheduleVisibilityCheck();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncTimer();
    if (_foreground) _scheduleVisibilityCheck();
  }

  @override
  void didChangeMetrics() => _scheduleVisibilityCheck();

  bool _isVisible() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return false;
    var viewport = Offset.zero & MediaQuery.sizeOf(context);
    final scrollBox = Scrollable.maybeOf(context)?.context.findRenderObject();
    if (scrollBox is RenderBox && scrollBox.attached && scrollBox.hasSize) {
      viewport = viewport.intersect(
        scrollBox.localToGlobal(Offset.zero) & scrollBox.size,
      );
    }
    final bounds = box.localToGlobal(Offset.zero) & box.size;
    return !viewport.isEmpty && !bounds.isEmpty && viewport.overlaps(bounds);
  }

  void _scheduleVisibilityCheck() {
    if (_checkScheduled) return;
    _checkScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkScheduled = false;
      if (!mounted) return;
      _visible = _isVisible();
      _syncTimer();
    });
  }

  void _syncTimer() {
    if (!_enabled ||
        !_foreground ||
        !_visible ||
        _interacted ||
        widget.items.length < 2) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer(const Duration(seconds: 8), () {
      _timer = null;
      if (!mounted) return;
      _visible = _isVisible();
      if (_enabled && _foreground && _visible && !_interacted) {
        setState(() => _index = (_index + 1) % widget.items.length);
      }
      _syncTimer();
    });
  }

  void _pause() {
    if (_interacted) return;
    setState(() => _interacted = true);
    _syncTimer();
  }

  void _next() {
    _pause();
    setState(() => _index = (_index + 1) % widget.items.length);
  }

  void _open(NoticeListItems item) {
    _pause();
    final source = CapabilitySourceScope.maybeOf(context)?.source;
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => NoticeDetailPage(item: item, source: source),
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scroll?.removeListener(_scheduleVisibilityCheck);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (widget.items.isEmpty) return Text(l10n.homeNoticeCount(0));
    final item = widget.items[_index];
    final theme = Theme.of(context);
    final scale = MediaQuery.textScalerOf(context);
    final summary = item.summary?.trim();
    final metadata = [
      item.source,
      if (item.publishedAtDateTime != null)
        formatLocalDate(item.publishedAtDateTime!),
    ].where((value) => value.trim().isNotEmpty).join(' · ');
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : 180.0;
        // Reserve real line heights; text scaling reduces the number of lines,
        // rather than overflowing the finite home card into its neighbours.
        final titleLine =
            scale.scale(theme.textTheme.titleSmall!.fontSize!) * 1.5;
        final bodyLine =
            scale.scale(theme.textTheme.bodySmall!.fontSize!) * 1.5;
        final controls = widget.items.length > 1 && height >= titleLine + 56;
        final contentHeight = (height - (controls ? 48 : 0)).clamp(0.0, height);
        final titleLines = contentHeight >= titleLine * 2 + bodyLine + 8
            ? 2
            : 1;
        var remaining = contentHeight - titleLine * titleLines;
        final metadataVisible =
            metadata.isNotEmpty && remaining >= bodyLine + 4;
        if (metadataVisible) remaining -= bodyLine + 4;
        final summaryLines = summary != null && summary.isNotEmpty
            ? ((remaining - 4) / bodyLine).floor().clamp(0, 2)
            : 0;
        return Focus(
          onFocusChange: (focused) {
            if (focused) _pause();
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Flexible(
                child: InkWell(
                  key: ValueKey('notice-summary-${item.id}'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _open(item),
                  onTapDown: (_) => _pause(),
                  child: Semantics(
                    label: [item.title, ?summary, metadata].join('\n'),
                    excludeSemantics: true,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Flexible(
                          child: Text(
                            item.title,
                            maxLines: titleLines,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        if (summaryLines > 0) ...[
                          const SizedBox(height: 4),
                          Text(
                            summary!,
                            maxLines: summaryLines,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                        if (metadataVisible) ...[
                          const SizedBox(height: 4),
                          Text(
                            metadata,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              if (controls)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${_index + 1} / ${widget.items.length}',
                        maxLines: 1,
                        style: theme.textTheme.labelSmall,
                      ),
                    ),
                    IconButton(
                      tooltip: _interacted
                          ? l10n.noticeResumeSummary
                          : l10n.noticePauseSummary,
                      onPressed: _enabled
                          ? () {
                              setState(() => _interacted = !_interacted);
                              _syncTimer();
                            }
                          : null,
                      icon: Icon(_interacted ? Icons.play_arrow : Icons.pause),
                      iconSize: 20,
                    ),
                    IconButton(
                      tooltip: l10n.noticeNextSummary,
                      onPressed: _next,
                      icon: const Icon(Icons.navigate_next),
                      iconSize: 20,
                    ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}
