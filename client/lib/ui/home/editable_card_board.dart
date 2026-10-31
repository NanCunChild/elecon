/// Host-owned launcher layout. Business children keep their state when moved,
/// resized, or opened temporarily; only explicit layout edits are persisted.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../l10n/gen/app_localizations.dart';
import 'card_layout.dart';
import 'card_layout_store.dart';

class EditableCardBoard extends StatefulWidget {
  const EditableCardBoard({
    super.key,
    required this.scopeId,
    required this.cards,
    this.store,
  });
  final String scopeId;
  final List<HomeCardEntry> cards;
  final CardLayoutStore? store;

  @override
  State<EditableCardBoard> createState() => _EditableCardBoardState();
}

class _CardDrag {
  const _CardDrag(this.owner, this.scope, this.id);
  final Object owner;
  final String scope;
  final String id;
}

class _EditableCardBoardState extends State<EditableCardBoard> {
  final _owner = Object();
  final _gridKey = GlobalKey();
  final _heights = <String, double>{};
  final _slots = <String, Rect>{};
  HomeCardLayout _layout = HomeCardLayout();
  HomeCardLayout? _beforeDrag;
  bool _editing = false;
  bool _saveFailed = false;
  int _generation = 0;
  int _revision = 0;
  String? _dragging;
  String? _opened;
  String? _hovered;
  Timer? _scrollTimer;
  Timer? _hoverTimer;
  Offset? _pointer;
  Offset? _lastMove;

  CardLayoutStore get _store => widget.store ?? CardLayoutStore.shared;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(EditableCardBoard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scopeId != widget.scopeId ||
        oldWidget.store != widget.store) {
      _generation++;
      _revision = 0;
      _stopDrag();
      _layout = HomeCardLayout();
      _heights.clear();
      _opened = null;
      _editing = false;
      _saveFailed = false;
      _load();
    } else if (_dragging != null &&
        !widget.cards.any((c) => c.id == _dragging)) {
      _layout = _beforeDrag ?? _layout;
      _stopDrag();
    }
  }

  Future<void> _load() async {
    final generation = _generation;
    final revision = _revision;
    final layout = await _store.load(widget.scopeId);
    if (mounted && generation == _generation && revision == _revision) {
      setState(() => _layout = layout);
    }
  }

  @override
  void dispose() {
    _stopDrag();
    super.dispose();
  }

  void _stopDrag() {
    _scrollTimer?.cancel();
    _hoverTimer?.cancel();
    _dragging = null;
    _hovered = null;
    _beforeDrag = null;
    _pointer = null;
    _lastMove = null;
  }

  void _edit() {
    FocusScope.of(context).unfocus();
    setState(() {
      _editing = true;
      _revision++;
    });
  }

  void _change(HomeCardLayout layout) {
    setState(() {
      _layout = layout;
      _revision++;
    });
    unawaited(_persist());
  }

  Future<void> _persist() async {
    final generation = _generation;
    final revision = _revision;
    try {
      await _store.save(widget.scopeId, _layout);
      if (mounted && generation == _generation && revision == _revision) {
        setState(() => _saveFailed = false);
      }
    } catch (_) {
      if (mounted && generation == _generation && revision == _revision) {
        setState(() => _saveFailed = true);
      }
    }
  }

  bool _accepts(_CardDrag drag) =>
      identical(drag.owner, _owner) &&
      drag.scope == widget.scopeId &&
      drag.id == _dragging;

  void _startDrag(_CardDrag drag) {
    if (drag.scope != widget.scopeId) return;
    _edit();
    setState(() {
      _beforeDrag = _layout;
      _dragging = drag.id;
    });
    _scrollTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!mounted || _pointer == null) return;
      final scrollable = Scrollable.maybeOf(context);
      final box = scrollable?.context.findRenderObject();
      if (scrollable == null || box is! RenderBox || !box.hasSize) return;
      final y = box.globalToLocal(_pointer!).dy;
      const edge = 72.0;
      final delta = y < edge
          ? -((edge - y) / 6).clamp(0.0, 16.0)
          : y > box.size.height - edge
          ? ((y - box.size.height + edge) / 6).clamp(0.0, 16.0)
          : 0.0;
      final position = scrollable.position;
      final next = (position.pixels + delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if (next != position.pixels) {
        position.jumpTo(next);
        _considerMove(scrolling: true);
      }
    });
  }

  void _considerMove({bool scrolling = false}) {
    if (_dragging == null || _pointer == null) return;
    // A stationary pointer must not swap back as its neighbour animates past.
    if (!scrolling &&
        _lastMove != null &&
        (_pointer! - _lastMove!).distance < 18) {
      return;
    }
    final box = _gridKey.currentContext?.findRenderObject();
    if (box is! RenderBox) return;
    final local = box.globalToLocal(_pointer!);
    final point = Directionality.of(context) == TextDirection.rtl
        ? Offset(box.size.width - local.dx, local.dy)
        : local;
    final target = _slots.entries
        .where((e) => e.value.contains(point))
        .firstOrNull
        ?.key;
    if (target == _hovered) return;
    _hoverTimer?.cancel();
    _hovered = target;
    if (target == null || target == _dragging) return;
    final generation = _generation;
    _hoverTimer = Timer(const Duration(milliseconds: 140), () {
      if (!mounted || generation != _generation || _dragging == null) return;
      setState(() {
        _layout = _layout.move(_dragging!, target, widget.cards);
        _revision++;
        _lastMove = _pointer;
        _hovered = null;
      });
    });
  }

  void _endDrag(_CardDrag drag, DraggableDetails details) {
    if (!_accepts(drag)) return;
    setState(() {
      if (!details.wasAccepted) _layout = _beforeDrag ?? _layout;
      _stopDrag();
    });
    if (details.wasAccepted) unawaited(_persist());
  }

  String _sizeLabel(AppLocalizations l10n, HomeCardSize size) => switch (size) {
    HomeCardSize.compact => l10n.homeLayoutCompact,
    HomeCardSize.regular => l10n.homeLayoutRegular,
    HomeCardSize.expanded => l10n.homeLayoutExpanded,
  };

  Future<void> _menu(HomeCardEntry card) async {
    final generation = _generation;
    final l10n = AppLocalizations.of(context);
    final cards = _layout.arrange(widget.cards);
    final index = cards.indexWhere((c) => c.id == card.id);
    final result = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .85,
      ),
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(leading: Icon(card.icon), title: Text(card.label)),
              for (final size in card.sizes)
                ListTile(
                  key: ValueKey('home-card-size:${size.name}'),
                  leading: Icon(switch (size) {
                    HomeCardSize.compact => Icons.apps_rounded,
                    HomeCardSize.regular => Icons.view_column_outlined,
                    HomeCardSize.expanded => Icons.view_agenda_outlined,
                  }),
                  title: Text(_sizeLabel(l10n, size)),
                  trailing: card.supportedSize(_layout.sizes[card.id]) == size
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => Navigator.pop(context, size.name),
                ),
              ListTile(
                key: ValueKey('home-card-before:${card.id}'),
                enabled: index > 0,
                leading: const Icon(Icons.arrow_back),
                title: Text(l10n.homeLayoutMoveBefore),
                onTap: index > 0
                    ? () => Navigator.pop(context, 'before')
                    : null,
              ),
              ListTile(
                key: ValueKey('home-card-after:${card.id}'),
                enabled: index < cards.length - 1,
                leading: const Icon(Icons.arrow_forward),
                title: Text(l10n.homeLayoutMoveAfter),
                onTap: index < cards.length - 1
                    ? () => Navigator.pop(context, 'after')
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted ||
        result == null ||
        generation != _generation ||
        !widget.cards.any((c) => c.id == card.id)) {
      return;
    }
    if (result == 'before' || result == 'after') {
      _change(
        _layout.move(
          card.id,
          cards[index + (result == 'before' ? -1 : 1)].id,
          widget.cards,
        ),
      );
    } else {
      setState(() => _opened = null);
      _change(_layout.resize(card.id, HomeCardSize.values.byName(result)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cards = _layout.arrange(widget.cards);
    if (cards.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Wrap(
            children: [
              if (_editing)
                TextButton.icon(
                  onPressed: () {
                    setState(() => _opened = null);
                    _change(HomeCardLayout());
                  },
                  icon: const Icon(Icons.restore),
                  label: Text(l10n.homeLayoutReset),
                ),
              TextButton.icon(
                key: const ValueKey('home-layout-edit'),
                // Keep the grid stationary as the first long press picks up a card.
                // Gesture guidance is available without adding an editing frame.
                // The same menu is reachable by keyboard and screen readers.
                onPressed: _editing
                    ? () => setState(() => _editing = false)
                    : _edit,
                icon: Icon(
                  _editing ? Icons.check : Icons.dashboard_customize_outlined,
                ),
                label: Text(
                  _editing ? l10n.homeLayoutDone : l10n.homeLayoutEdit,
                ),
              ),
            ],
          ),
        ),
        if (_saveFailed)
          Wrap(
            children: [
              Text(l10n.homeLayoutSaveFailed),
              TextButton(
                onPressed: _persist,
                child: Text(l10n.homeLayoutRetry),
              ),
            ],
          ),
        LayoutBuilder(
          builder: (context, constraints) {
            const gap = 12.0;
            final width = constraints.maxWidth;
            final columns = width < 280 ? 2 : 4;
            final unit = (width - gap * (columns - 1)) / columns;
            final split =
                width >= 320 &&
                MediaQuery.textScalerOf(context).scale(14) <= 20;
            var x = 0.0, y = 0.0, rowHeight = 0.0;
            var used = 0;
            _slots.clear();
            for (final card in cards) {
              final size = _opened == card.id
                  ? HomeCardSize.expanded
                  : card.supportedSize(_layout.sizes[card.id]);
              final span = size == HomeCardSize.compact
                  ? 1
                  : size == HomeCardSize.regular && split
                  ? 2
                  : columns;
              if (used + span > columns) {
                used = 0;
                x = 0;
                y += rowHeight + gap;
                rowHeight = 0;
              }
              final tileWidth = unit * span + gap * (span - 1);
              final height =
                  _heights[card.id] ??
                  (size == HomeCardSize.compact ? 80.0 : 168.0);
              _slots[card.id] = Rect.fromLTWH(x, y, tileWidth, height);
              rowHeight = math.max(rowHeight, height);
              x += tileWidth + gap;
              used += span;
            }
            final duration = MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 220);
            return DragTarget<_CardDrag>(
              hitTestBehavior: HitTestBehavior.opaque,
              onWillAcceptWithDetails: (d) =>
                  identical(d.data.owner, _owner) &&
                  d.data.scope == widget.scopeId &&
                  widget.cards.any((c) => c.id == d.data.id),
              onAcceptWithDetails: (_) {},
              builder: (context, _, _) => SizedBox(
                key: _gridKey,
                height: y + rowHeight,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (final card in cards)
                      AnimatedPositioned(
                        key: ValueKey((widget.scopeId, card.id)),
                        duration: duration,
                        curve: Curves.easeOutCubic,
                        left: Directionality.of(context) == TextDirection.rtl
                            ? width - _slots[card.id]!.right
                            : _slots[card.id]!.left,
                        top: _slots[card.id]!.top,
                        width: _slots[card.id]!.width,
                        child: _MeasureSize(
                          onChange: (size) {
                            if (mounted && _heights[card.id] != size.height) {
                              setState(() => _heights[card.id] = size.height);
                            }
                          },
                          child: _tile(card, width),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _tile(HomeCardEntry card, double boardWidth) {
    final drag = _CardDrag(_owner, widget.scopeId, card.id);
    final size = _opened == card.id
        ? HomeCardSize.expanded
        : card.supportedSize(_layout.sizes[card.id]);
    final iconOnly = size == HomeCardSize.compact;
    final colors = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    void open() => setState(() => _opened = card.id);
    return LongPressDraggable<_CardDrag>(
      data: drag,
      maxSimultaneousDrags: _dragging == null ? 1 : 0,
      onDragStarted: () => _startDrag(drag),
      onDragUpdate: (details) {
        _pointer = details.globalPosition;
        _considerMove();
      },
      onDragEnd: (details) => _endDrag(drag, details),
      feedback: Material(
        elevation: 10,
        shadowColor: colors.shadow.withValues(alpha: .2),
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(card.icon, color: colors.onPrimaryContainer),
              const SizedBox(width: 12),
              Text(
                card.label,
                style: TextStyle(color: colors.onPrimaryContainer),
              ),
            ],
          ),
        ),
      ),
      child: AnimatedOpacity(
        opacity: _dragging == card.id ? .18 : 1,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 120),
        child: Semantics(
          label: _editing ? card.label : null,
          button: _editing,
          onTap: _editing ? () => _menu(card) : null,
          child: InkWell(
            key: ValueKey('home-card:${card.id}'),
            onTap: _editing ? () => _menu(card) : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (iconOnly)
                  SizedBox(
                    height: 80,
                    child: Center(
                      child: TooltipTheme(
                        // Leave the long-press gesture to the launcher drag.
                        // The tooltip still provides hover and semantic labels.
                        data: TooltipTheme.of(
                          context,
                        ).copyWith(triggerMode: TooltipTriggerMode.manual),
                        child: IconButton.filledTonal(
                          key: ValueKey('home-card-open:${card.id}'),
                          tooltip: card.label,
                          onPressed: _editing ? () => _menu(card) : open,
                          style: IconButton.styleFrom(
                            minimumSize: const Size(56, 56),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                          ),
                          icon: Icon(card.icon, size: 28),
                        ),
                      ),
                    ),
                  ),
                if (_opened == card.id)
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton.icon(
                      key: ValueKey('home-card-close:${card.id}'),
                      onPressed: _editing
                          ? null
                          : () => setState(() => _opened = null),
                      icon: const Icon(Icons.unfold_less),
                      label: Text(l10n.homeCardCollapse),
                    ),
                  ),
                Offstage(
                  offstage: iconOnly,
                  child: TickerMode(
                    enabled: !iconOnly,
                    child: OverflowBox(
                      fit: OverflowBoxFit.deferToChild,
                      minWidth: iconOnly ? boardWidth : null,
                      maxWidth: iconOnly ? boardWidth : null,
                      child: HomeCardPresentation(
                        size: size,
                        icon: card.icon,
                        onOpen: open,
                        child: AbsorbPointer(
                          absorbing: _editing || iconOnly,
                          child: ExcludeFocus(
                            excluding: _editing || iconOnly,
                            child: ExcludeSemantics(
                              excluding: _editing || iconOnly,
                              child: KeyedSubtree(
                                key: ValueKey('home-card-content:${card.id}'),
                                child: Builder(builder: card.builder),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MeasureSize extends SingleChildRenderObjectWidget {
  const _MeasureSize({required this.onChange, required super.child});
  final ValueChanged<Size> onChange;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _MeasureRenderBox(onChange);
  @override
  void updateRenderObject(
    BuildContext context,
    _MeasureRenderBox renderObject,
  ) => renderObject.onChange = onChange;
}

class _MeasureRenderBox extends RenderProxyBox {
  _MeasureRenderBox(this.onChange);
  ValueChanged<Size> onChange;
  Size? _previous;
  @override
  void performLayout() {
    super.performLayout();
    if (_previous == size) return;
    _previous = size;
    final measured = size;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (attached) onChange(measured);
    });
  }
}
