/// Host-owned launcher layout. Business children keep their state when moved,
/// resized, or opened temporarily; only explicit layout edits are persisted.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../l10n/gen/app_localizations.dart';
import 'card_layout.dart';
import 'feature_page.dart';
import '../../session/session_scope.dart';
import '../../session/session_controller.dart';
import 'card_grid.dart';
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
  final _contentKeys = <String, GlobalKey>{};
  final _activePages = <String, ValueNotifier<bool>>{};
  final _slots = <String, Rect>{};
  HomeCardLayout _layout = HomeCardLayout();
  HomeCardLayout? _beforeDrag;
  bool _editing = false;
  bool _saveFailed = false;
  int _generation = 0;
  int _revision = 0;
  String? _dragging;
  HomeCardPosition? _hovered;
  HomeCardGrid? _grid;
  Map<String, HomeCardPosition> _locations = {};
  Map<String, HomeCardSpan> _spans = {};
  Map<String, HomeCardPosition>? _dragLocations;
  Offset _pickupOffset = Offset.zero;
  Timer? _scrollTimer;
  Timer? _hoverTimer;
  Offset? _pointer;

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
      _contentKeys.clear();
      _activePages.clear();
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
    _dragLocations = null;
    _pointer = null;
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
      // Drag geometry follows the saved home layout.
      final spans = {
        for (final card in _layout.visible(widget.cards))
          card.id: _grid!.span(
            card.supportedSize(_layout.sizes[card.id]),
            contentHeight: _heights[card.id] ?? 0,
          ),
      };
      _dragLocations = _grid!.place(spans, _layout.positions);
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

  void _moveTo(String id, HomeCardPosition target, {bool save = false}) {
    final grid = _grid;
    if (grid == null || !_spans.containsKey(id)) return;
    final locations = grid.place(_spans, {
      ...(_dragLocations ?? _locations),
      id: target,
    }, priority: save ? null : id);
    setState(() {
      _layout = _layout.locate(locations);
      _revision++;
    });
    if (save) unawaited(_persist());
  }

  void _considerMove({bool scrolling = false, bool immediate = false}) {
    if (_dragging == null || _pointer == null || _grid == null) return;
    final box = _gridKey.currentContext?.findRenderObject();
    if (box is! RenderBox) return;
    final local = box.globalToLocal(_pointer!);
    if (!(Offset.zero & box.size).contains(local)) return;
    final grid = _grid!;
    final span = _spans[_dragging!]!;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final x = rtl ? box.size.width - local.dx : local.dx;
    final anchorX = rtl
        ? grid.widthOf(span) - _pickupOffset.dx
        : _pickupOffset.dx;
    final target = HomeCardPosition(
      ((x - anchorX) / (grid.cellWidth + HomeCardGrid.gap)).round().clamp(
        0,
        grid.columns - span.columns,
      ),
      ((local.dy - _pickupOffset.dy) / (grid.cellHeight + HomeCardGrid.gap))
          .round()
          .clamp(0, 1023),
    );
    if (immediate) {
      _hoverTimer?.cancel();
      _moveTo(_dragging!, target);
      return;
    }
    if (target == _hovered) return;
    _hoverTimer?.cancel();
    _hovered = target;
    final generation = _generation;
    _hoverTimer = Timer(const Duration(milliseconds: 140), () {
      if (!mounted || generation != _generation || _dragging == null) return;
      _moveTo(_dragging!, target);
    });
  }

  void _endDrag(_CardDrag drag, DraggableDetails details) {
    if (!_accepts(drag)) return;
    if (details.wasAccepted) _considerMove(immediate: true);
    setState(() {
      if (!details.wasAccepted) {
        _layout = _beforeDrag ?? _layout;
      } else {
        _layout = _layout.locate(_grid!.place(_spans, _layout.positions));
      }
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
    if (_dragging != null) return;
    final generation = _generation;
    final l10n = AppLocalizations.of(context);
    final cards = _layout.visible(widget.cards);
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
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final direction in [
                    ('up', 0, -1, Icons.arrow_upward, l10n.homeLayoutMoveUp),
                    (
                      'down',
                      0,
                      1,
                      Icons.arrow_downward,
                      l10n.homeLayoutMoveDown,
                    ),
                    ('left', -1, 0, Icons.arrow_back, l10n.homeLayoutMoveLeft),
                    (
                      'right',
                      1,
                      0,
                      Icons.arrow_forward,
                      l10n.homeLayoutMoveRight,
                    ),
                  ])
                    IconButton(
                      key: ValueKey('home-card-grid:${direction.$1}'),
                      tooltip: direction.$5,
                      onPressed: () =>
                          Navigator.pop(context, 'grid:${direction.$1}'),
                      icon: Icon(
                        direction.$4,
                        textDirection: TextDirection.ltr,
                      ),
                    ),
                ],
              ),
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
                  onTap: () => Navigator.pop(context, 'size:${size.name}'),
                ),
              if (card.presets.isNotEmpty) ...[
                const Divider(),
                ListTile(title: Text(l10n.homeLayoutPreset)),
                for (final preset in [
                  (HomeCardPreset.standard, l10n.homeLayoutPresetStandard),
                  for (final preset in card.presets) (preset.id, preset.label),
                ])
                  ListTile(
                    key: ValueKey('home-card-preset:${preset.$1}'),
                    leading: const Icon(Icons.style_outlined),
                    title: Text(preset.$2),
                    trailing:
                        card.supportedPreset(_layout.presets[card.id]) ==
                            preset.$1
                        ? const Icon(Icons.check)
                        : null,
                    onTap: () => Navigator.pop(context, 'preset:${preset.$1}'),
                  ),
                const Divider(),
              ],
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
              ListTile(
                key: ValueKey('home-card-hide:${card.id}'),
                leading: const Icon(Icons.visibility_off_outlined),
                title: Text(l10n.homeLayoutHide),
                onTap: () => Navigator.pop(context, 'hide'),
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
    if (result.startsWith('grid:')) {
      final current = _locations[card.id];
      if (current == null || _grid == null) return;
      final horizontal = Directionality.of(context) == TextDirection.rtl
          ? -1
          : 1;
      final delta = switch (result.substring(5)) {
        'up' => (0, -1),
        'down' => (0, 1),
        'left' => (-horizontal, 0),
        _ => (horizontal, 0),
      };
      _moveTo(
        card.id,
        HomeCardPosition(
          (current.column + delta.$1).clamp(
            0,
            _grid!.columns - _spans[card.id]!.columns,
          ),
          (current.row + delta.$2).clamp(0, 1023),
        ),
        save: true,
      );
    } else if (result == 'before' || result == 'after') {
      final targetId = cards[index + (result == 'before' ? -1 : 1)].id;
      final moved = _layout.move(card.id, targetId, widget.cards);
      final preferred = Map.of(_locations)
        ..remove(card.id)
        ..remove(targetId);
      final placed = _grid!.place({
        for (final item in moved.visible(widget.cards))
          item.id: _spans[item.id]!,
      }, preferred);
      _change(moved.locate(placed));
    } else if (result == 'hide') {
      _change(_layout.show(card.id, false));
    } else if (result.startsWith('preset:')) {
      _change(_layout.selectPreset(card.id, result.substring(7)));
    } else if (result.startsWith('size:')) {
      final resized = _layout.resize(
        card.id,
        HomeCardSize.values.byName(result.substring(5)),
      );
      final spans = {
        for (final item in resized.visible(widget.cards))
          item.id: _grid!.span(
            item.supportedSize(resized.sizes[item.id]),
            contentHeight: _heights[item.id] ?? 0,
          ),
      };
      _change(
        resized.locate(_grid!.place(spans, _locations, priority: card.id)),
      );
    }
  }

  Future<void> _manage() async {
    if (_dragging != null) return;
    final generation = _generation;
    FocusScope.of(context).unfocus();
    final l10n = AppLocalizations.of(context);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .85,
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, updateSheet) {
          void change(HomeCardLayout layout) {
            if (!mounted || generation != _generation) {
              Navigator.pop(sheetContext);
              return;
            }
            _change(layout);
            updateSheet(() {});
          }

          return SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                    title: Text(l10n.homeLayoutManage),
                    subtitle: Text(l10n.homeLayoutManageHint),
                  ),
                  for (final card in _layout.arrange(widget.cards))
                    SwitchListTile(
                      key: ValueKey('home-card-visible:${card.id}'),
                      secondary: Icon(card.icon),
                      title: Text(card.label),
                      value: !_layout.hidden.contains(card.id),
                      onChanged: (visible) {
                        if (widget.cards.any((c) => c.id == card.id)) {
                          change(_layout.show(card.id, visible));
                        }
                      },
                    ),
                  ListTile(
                    leading: const Icon(Icons.restore),
                    title: Text(l10n.homeLayoutReset),
                    onTap: () => change(HomeCardLayout()),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: FilledButton(
                      onPressed: () => Navigator.pop(sheetContext),
                      child: Text(l10n.homeLayoutDone),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cards = _layout.visible(widget.cards);
    if (widget.cards.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Wrap(
            children: [
              TextButton.icon(
                key: const ValueKey('home-layout-manage'),
                onPressed: _dragging == null ? _manage : null,
                icon: const Icon(Icons.tune),
                label: Text(l10n.homeLayoutManage),
              ),
              TextButton.icon(
                key: const ValueKey('home-layout-edit'),
                // Keep the grid stationary as the first long press picks up a card.
                // Gesture guidance is available without adding an editing frame.
                // The same menu is reachable by keyboard and screen readers.
                onPressed: _dragging != null
                    ? null
                    : _editing
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
        if (cards.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
            child: Text(l10n.homeLayoutEmpty, textAlign: TextAlign.center),
          ),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final labelStyle = Theme.of(context).textTheme.labelMedium!;
            final labelHeight =
                MediaQuery.textScalerOf(context).scale(labelStyle.fontSize!) *
                (labelStyle.height ?? 1.3);
            final grid = HomeCardGrid(width: width, labelHeight: labelHeight);
            _grid = grid;
            _spans = {
              for (final card in cards)
                card.id: grid.span(
                  card.supportedSize(_layout.sizes[card.id]),
                  contentHeight: _heights[card.id] ?? 0,
                ),
            };
            _locations = grid.place(
              _spans,
              _layout.positions,
              priority: _dragging,
            );
            _slots.clear();
            var bottom = 0.0;
            for (final card in cards) {
              final position = _locations[card.id]!;
              final span = _spans[card.id]!;
              final rect = Rect.fromLTWH(
                position.column * (grid.cellWidth + HomeCardGrid.gap),
                position.row * (grid.cellHeight + HomeCardGrid.gap),
                grid.widthOf(span),
                grid.heightOf(span),
              );
              _slots[card.id] = rect;
              bottom = math.max(bottom, rect.bottom);
            }
            final gridHeight =
                bottom +
                (_editing ? 2 * (grid.cellHeight + HomeCardGrid.gap) : 0);
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
                height: gridHeight,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    if (_dragging != null)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CustomPaint(
                            painter: _GridDots(
                              grid,
                              Theme.of(context).colorScheme.outlineVariant,
                            ),
                          ),
                        ),
                      ),
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
                        height: _slots[card.id]!.height,
                        child: Material(
                          key: ValueKey('home-card-slot:${card.id}'),
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(24),
                          clipBehavior: Clip.antiAlias,
                          child: OverflowBox(
                            alignment: Alignment.topCenter,
                            fit: OverflowBoxFit.deferToChild,
                            minHeight: 0,
                            maxHeight: double.infinity,
                            child: _MeasureSize(
                              onChange: (size) {
                                if (mounted &&
                                    (card.supportedSize(
                                          _layout.sizes[card.id],
                                        ) ==
                                        HomeCardSize.expanded) &&
                                    _heights[card.id] != size.height) {
                                  setState(
                                    () => _heights[card.id] = size.height,
                                  );
                                }
                              },
                              child: _tile(card, width),
                            ),
                          ),
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
    final size = card.supportedSize(_layout.sizes[card.id]);
    final compact = size == HomeCardSize.compact;
    final colors = Theme.of(context).colorScheme;
    final contentKey = _contentKeys.putIfAbsent(card.id, GlobalKey.new);
    final active = _activePages.putIfAbsent(
      card.id,
      () => ValueNotifier(false),
    );
    void open() {
      final session = context
          .getInheritedWidgetOfExactType<SessionScope>()
          ?.notifier;
      setState(() => active.value = true);
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => HomeFeaturePage(
            card: card,
            contentKey: contentKey,
            active: active,
            preset: card.supportedPreset(_layout.presets[card.id]),
            session: session,
            generation: session?.trustedScriptViewGeneration,
            onClosed: () {
              if (mounted) setState(() {});
            },
          ),
        ),
      );
    }

    if (active.value) {
      return SizedBox(height: _slots[card.id]!.height);
    }
    return LongPressDraggable<_CardDrag>(
      data: drag,
      dragAnchorStrategy: (draggable, context, position) {
        final box = context.findRenderObject() as RenderBox;
        _pickupOffset = box.globalToLocal(position);
        return _pickupOffset;
      },
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
                if (compact)
                  SizedBox(
                    height: _grid!.cellHeight,
                    child: Tooltip(
                      // Leave long press to the launcher drag recognizer.
                      triggerMode: TooltipTriggerMode.manual,
                      excludeFromSemantics: true,
                      message: card.label,
                      child: FilledButton.tonal(
                        key: ValueKey('home-card-open:${card.id}'),
                        onPressed: _editing ? () => _menu(card) : open,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 8,
                          ),
                          minimumSize: const Size(0, 0),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(card.icon, size: 32),
                            const SizedBox(height: 6),
                            Text(
                              card.label,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                Offstage(
                  offstage: compact,
                  child: TickerMode(
                    enabled: !compact,
                    child: OverflowBox(
                      fit: OverflowBoxFit.deferToChild,
                      minWidth: compact ? boardWidth : null,
                      maxWidth: compact ? boardWidth : null,
                      child: HomeCardPresentation(
                        size: size,
                        previewHeight: size == HomeCardSize.regular
                            ? _slots[card.id]!.height
                            : null,
                        preset: card.supportedPreset(_layout.presets[card.id]),
                        icon: card.icon,
                        onOpen: open,
                        child: AbsorbPointer(
                          absorbing: _editing || compact,
                          child: ExcludeFocus(
                            excluding: _editing || compact,
                            child: ExcludeSemantics(
                              excluding: _editing || compact,
                              child: KeyedSubtree(
                                key: contentKey,
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

class _GridDots extends CustomPainter {
  const _GridDots(this.grid, this.color);
  final HomeCardGrid grid;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (
      var y = grid.cellHeight / 2;
      y < size.height;
      y += grid.cellHeight + HomeCardGrid.gap
    ) {
      for (
        var x = grid.cellWidth / 2;
        x < size.width;
        x += grid.cellWidth + HomeCardGrid.gap
      ) {
        canvas.drawCircle(Offset(x, y), 2, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_GridDots old) => old.grid != grid || old.color != color;
}
