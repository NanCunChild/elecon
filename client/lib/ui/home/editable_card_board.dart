/// ADR-043 §2: local finite layouts; scripts cannot supply widget trees.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

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
  const _CardDrag(this.owner, this.scopeId, this.id);
  final Object owner;
  final String scopeId;
  final String id;
}

class _EditableCardBoardState extends State<EditableCardBoard> {
  final _dragOwner = Object();
  HomeCardLayout _layout = HomeCardLayout();
  bool _editing = false;
  bool _saveFailed = false;
  int _generation = 0;
  int _revision = 0;
  String? _dragging;
  Timer? _dragScroll;
  Offset? _dragPosition;
  String? _resizing;
  Offset _resizeDelta = Offset.zero;
  HomeCardSize? _resizeStart;
  Axis? _resizeAxis;
  HomeCardSize? _resizePreview;

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
      _layout = HomeCardLayout();
      _editing = false;
      _saveFailed = false;
      _dragging = null;
      _dragScroll?.cancel();
      _dragPosition = null;
      _resizing = null;
      _resizePreview = null;
      _load();
    }
  }

  Future<void> _load() async {
    final generation = _generation;
    final revision = _revision;
    final scopeId = widget.scopeId;
    final layout = await _store.load(scopeId);
    if (!mounted ||
        generation != _generation ||
        revision != _revision ||
        scopeId != widget.scopeId) {
      return;
    }
    setState(() => _layout = layout);
  }

  @override
  void dispose() {
    _dragScroll?.cancel();
    super.dispose();
  }

  bool _accepts(_CardDrag drag, String targetId) =>
      _editing &&
      identical(drag.owner, _dragOwner) &&
      drag.scopeId == widget.scopeId &&
      drag.id != targetId &&
      widget.cards.any((card) => card.id == drag.id);

  void _startDrag(_CardDrag drag) {
    if (!_editing || drag.scopeId != widget.scopeId) return;
    setState(() => _dragging = drag.id);
    _dragScroll?.cancel();
    _dragScroll = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!mounted || _dragPosition == null || _dragging == null) return;
      final scrollable = Scrollable.maybeOf(context);
      final box = scrollable?.context.findRenderObject();
      if (scrollable == null || box is! RenderBox || !box.hasSize) return;
      final y = box.globalToLocal(_dragPosition!).dy;
      const edge = 72.0;
      final delta = y < edge
          ? -((edge - y) / 6).clamp(0.0, 16.0)
          : y > box.size.height - edge
          ? ((y - box.size.height + edge) / 6).clamp(0.0, 16.0)
          : 0.0;
      if (delta == 0) return;
      final position = scrollable.position;
      final next = (position.pixels + delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if (next != position.pixels) position.jumpTo(next);
    });
  }

  void _endDrag(_CardDrag drag) {
    if (drag.scopeId != widget.scopeId || _dragging != drag.id) return;
    _dragScroll?.cancel();
    _dragPosition = null;
    if (mounted) setState(() => _dragging = null);
  }

  void _edit() {
    if (_editing) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _editing = true;
      // A late load cannot overwrite the layout the user started editing.
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
    final scopeId = widget.scopeId;
    final layout = _layout;
    try {
      await _store.save(scopeId, layout);
      if (mounted && generation == _generation && revision == _revision) {
        setState(() => _saveFailed = false);
      }
    } catch (_) {
      if (mounted && generation == _generation && revision == _revision) {
        setState(() => _saveFailed = true);
      }
    }
  }

  HomeCardSize _size(HomeCardEntry card) => card.supportedSize(
    _resizing == card.id ? _resizePreview : _layout.sizes[card.id],
  );

  void _resize(HomeCardEntry card, HomeCardSize size) {
    if (!card.sizes.contains(size)) return;
    _change(_layout.resize(card.id, size));
  }

  void _move(String from, String to) {
    _change(_layout.move(from, to, widget.cards));
  }

  void _startResize(HomeCardEntry card, Axis axis) {
    setState(() {
      _resizing = card.id;
      _resizeAxis = axis;
      _resizeDelta = Offset.zero;
      _resizeStart = card.supportedSize(_layout.sizes[card.id]);
      _resizePreview = _resizeStart;
    });
  }

  void _updateResize(HomeCardEntry card, DragUpdateDetails details) {
    if (_resizing != card.id) return;
    _resizeDelta += details.delta;
    final extent = _resizeDelta.dx.abs() > _resizeDelta.dy.abs()
        ? _resizeDelta.dx
        : _resizeDelta.dy;
    final steps = (extent / 48).truncate();
    final choices = HomeCardSize.values.where(card.sizes.contains).toList();
    final index = (choices.indexOf(_resizeStart!) + steps).clamp(
      0,
      choices.length - 1,
    );
    final size = choices[index];
    if (size != _resizePreview) {
      setState(() => _resizePreview = size);
    }
  }

  void _finishResize(
    HomeCardEntry card, {
    bool cancel = false,
    required Axis axis,
  }) {
    if (_resizing != card.id || _resizeAxis != axis) return;
    final size = _resizePreview;
    setState(() {
      _resizing = null;
      _resizePreview = null;
    });
    if (!cancel && size != null) _resize(card, size);
  }

  String _sizeLabel(AppLocalizations l10n, HomeCardSize size) => switch (size) {
    HomeCardSize.compact => l10n.homeLayoutCompact,
    HomeCardSize.regular => l10n.homeLayoutRegular,
    HomeCardSize.expanded => l10n.homeLayoutExpanded,
  };

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
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (_editing)
                TextButton.icon(
                  key: const ValueKey('home-layout-reset'),
                  onPressed: () => _change(HomeCardLayout()),
                  icon: const Icon(Icons.restore),
                  label: Text(l10n.homeLayoutReset),
                ),
              TextButton.icon(
                key: const ValueKey('home-layout-edit'),
                onPressed: _editing
                    ? () => setState(() => _editing = false)
                    : _edit,
                icon: Icon(_editing ? Icons.check : Icons.dashboard_customize),
                label: Text(
                  _editing ? l10n.homeLayoutDone : l10n.homeLayoutEdit,
                ),
              ),
            ],
          ),
        ),
        if (_editing)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              l10n.homeLayoutHint,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (_saveFailed)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(l10n.homeLayoutSaveFailed),
                TextButton(
                  onPressed: () => unawaited(_persist()),
                  child: Text(l10n.homeLayoutRetry),
                ),
              ],
            ),
          ),
        LayoutBuilder(
          builder: (context, constraints) {
            const gap = 12.0;
            final canSplit =
                constraints.maxWidth >= 560 &&
                MediaQuery.textScalerOf(context).scale(14) <= 18.2;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (var index = 0; index < cards.length; index++)
                  _tile(
                    cards[index],
                    index,
                    cards,
                    _size(cards[index]) == HomeCardSize.compact && canSplit
                        ? (constraints.maxWidth - gap) / 2
                        : constraints.maxWidth,
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _tile(
    HomeCardEntry card,
    int index,
    List<HomeCardEntry> cards,
    double width,
  ) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final drag = _CardDrag(_dragOwner, widget.scopeId, card.id);
    return SizedBox(
      key: ValueKey((widget.scopeId, card.id)),
      width: width,
      child: DragTarget<_CardDrag>(
        onWillAcceptWithDetails: (details) => _accepts(details.data, card.id),
        onAcceptWithDetails: (details) {
          if (_accepts(details.data, card.id)) _move(details.data.id, card.id);
        },
        builder: (context, candidates, rejected) {
          return LongPressDraggable<_CardDrag>(
            data: drag,
            maxSimultaneousDrags: _editing ? 1 : 0,
            feedback: _feedback(card, width),
            onDragStarted: () => _startDrag(drag),
            onDragEnd: (_) => _endDrag(drag),
            child: Listener(
              onPointerDown: (event) => _dragPosition = event.position,
              onPointerMove: (event) => _dragPosition = event.position,
              child: GestureDetector(
                key: ValueKey('home-card:${card.id}'),
                behavior: HitTestBehavior.opaque,
                onLongPress: _editing ? null : _edit,
                child: Opacity(
                  opacity: _dragging == card.id ? 0.45 : 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        width: _editing ? 2 : 0,
                        color: candidates.isNotEmpty || _resizing == card.id
                            ? colors.primary
                            : _editing
                            ? colors.outlineVariant
                            : Colors.transparent,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_editing)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        card.label,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.labelLarge,
                                      ),
                                    ),
                                    Draggable<_CardDrag>(
                                      affinity: Axis.vertical,
                                      data: drag,
                                      feedback: _feedback(card, width),
                                      onDragStarted: () => _startDrag(drag),
                                      onDragEnd: (_) => _endDrag(drag),
                                      child: Tooltip(
                                        message: l10n.homeLayoutHint,
                                        child: Padding(
                                          key: ValueKey(
                                            'home-card-drag:${card.id}',
                                          ),
                                          padding: const EdgeInsets.all(12),
                                          child: const Icon(
                                            Icons.drag_indicator,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                Wrap(
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    IconButton(
                                      key: ValueKey(
                                        'home-card-before:${card.id}',
                                      ),
                                      tooltip: l10n.homeLayoutMoveBefore,
                                      onPressed: index == 0
                                          ? null
                                          : () => _move(
                                              card.id,
                                              cards[index - 1].id,
                                            ),
                                      icon: const Icon(Icons.arrow_upward),
                                    ),
                                    IconButton(
                                      key: ValueKey(
                                        'home-card-after:${card.id}',
                                      ),
                                      tooltip: l10n.homeLayoutMoveAfter,
                                      onPressed: index == cards.length - 1
                                          ? null
                                          : () => _move(
                                              card.id,
                                              cards[index + 1].id,
                                            ),
                                      icon: const Icon(Icons.arrow_downward),
                                    ),
                                    if (card.sizes.length > 1)
                                      PopupMenuButton<HomeCardSize>(
                                        key: ValueKey(
                                          'home-card-size:${card.id}',
                                        ),
                                        tooltip: l10n.homeLayoutResize,
                                        onSelected: (size) =>
                                            _resize(card, size),
                                        itemBuilder: (_) => [
                                          for (final size
                                              in HomeCardSize.values)
                                            if (card.sizes.contains(size))
                                              CheckedPopupMenuItem(
                                                value: size,
                                                checked: _size(card) == size,
                                                child: Text(
                                                  _sizeLabel(l10n, size),
                                                ),
                                              ),
                                        ],
                                        child: Padding(
                                          padding: const EdgeInsets.all(12),
                                          child: Text(
                                            _sizeLabel(l10n, _size(card)),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        KeyedSubtree(
                          key: ValueKey('home-card-content:${card.id}'),
                          child: HomeCardPresentation(
                            size: _size(card),
                            child: AbsorbPointer(
                              absorbing: _editing,
                              child: ExcludeFocus(
                                excluding: _editing,
                                child: ExcludeSemantics(
                                  excluding: _editing,
                                  child: Builder(builder: card.builder),
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (_editing && card.sizes.length > 1)
                          Align(
                            alignment: AlignmentDirectional.bottomEnd,
                            child: GestureDetector(
                              key: ValueKey('home-card-resize:${card.id}'),
                              dragStartBehavior: DragStartBehavior.down,
                              onHorizontalDragStart: (_) =>
                                  _startResize(card, Axis.horizontal),
                              onHorizontalDragUpdate: (details) =>
                                  _updateResize(card, details),
                              onHorizontalDragEnd: (_) =>
                                  _finishResize(card, axis: Axis.horizontal),
                              onHorizontalDragCancel: () => _finishResize(
                                card,
                                cancel: true,
                                axis: Axis.horizontal,
                              ),
                              onVerticalDragStart: (_) =>
                                  _startResize(card, Axis.vertical),
                              onVerticalDragUpdate: (details) =>
                                  _updateResize(card, details),
                              onVerticalDragEnd: (_) =>
                                  _finishResize(card, axis: Axis.vertical),
                              onVerticalDragCancel: () => _finishResize(
                                card,
                                cancel: true,
                                axis: Axis.vertical,
                              ),
                              child: Listener(
                                onPointerCancel: (_) {
                                  final axis = _resizeAxis;
                                  if (axis != null) {
                                    _finishResize(
                                      card,
                                      cancel: true,
                                      axis: axis,
                                    );
                                  }
                                },
                                child: IconButton(
                                  tooltip: l10n.homeLayoutResize,
                                  onPressed: () {
                                    final choices = HomeCardSize.values
                                        .where(card.sizes.contains)
                                        .toList();
                                    _resize(
                                      card,
                                      choices[(choices.indexOf(_size(card)) +
                                              1) %
                                          choices.length],
                                    );
                                  },
                                  icon: Icon(
                                    Icons.open_in_full,
                                    color: colors.primary,
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
            ),
          );
        },
      ),
    );
  }

  Widget _feedback(HomeCardEntry card, double width) => Material(
    elevation: 8,
    borderRadius: BorderRadius.circular(16),
    color: Theme.of(context).colorScheme.primaryContainer,
    child: SizedBox(
      width: width.clamp(120.0, 360.0),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(card.label, style: Theme.of(context).textTheme.titleMedium),
      ),
    ),
  );
}
