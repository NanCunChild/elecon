/// ADR-079: shrink a single line before scrolling, with accessible static text.
library;

import 'package:flutter/material.dart';

class AdaptiveSchoolTitle extends StatefulWidget {
  const AdaptiveSchoolTitle({
    super.key,
    required this.text,
    this.style,
    this.minimumFontSize = 18,
  });

  final String text;
  final TextStyle? style;
  final double minimumFontSize;

  @override
  State<AdaptiveSchoolTitle> createState() => _AdaptiveSchoolTitleState();
}

class _AdaptiveSchoolTitleState extends State<AdaptiveSchoolTitle>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _scroll = ScrollController();
  late final AnimationController _motion = AnimationController(vsync: this)
    ..addListener(_move);
  late final Animation<double> _position = TweenSequence<double>([
    TweenSequenceItem(tween: ConstantTween(0.0), weight: 15),
    TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 35),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 15),
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 35),
  ]).animate(_motion);
  Object? _layout;
  double _overflow = 0;
  bool _enabled = false;
  bool _dragging = false;
  bool _foreground = true;
  int _revision = 0;

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
    _enabled =
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context) &&
        !MediaQuery.accessibleNavigationOf(context) &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  void _sync() {
    if (_enabled && _foreground && !_dragging && _overflow > 0) {
      if (!_motion.isAnimating) _motion.repeat();
    } else {
      _motion.stop();
    }
  }

  void _move() {
    if (!_scroll.hasClients || !_scroll.position.hasContentDimensions) return;
    final offset = _scroll.position.maxScrollExtent * _position.value;
    if ((_scroll.offset - offset).abs() > .1) _scroll.jumpTo(offset);
  }

  void _configure(Object layout, double overflow) {
    if (_layout == layout) return;
    _layout = layout;
    final revision = ++_revision;
    _motion.stop();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || revision != _revision) return;
      _overflow = overflow;
      _motion.duration = Duration(
        milliseconds: ((overflow * 2 / 30 + 3) * 1000)
            .clamp(7000, 120000)
            .round(),
      );
      _motion.value = 0;
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _sync();
    });
  }

  @override
  void dispose() {
    _revision++;
    WidgetsBinding.instance.removeObserver(this);
    _motion.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(
      context,
    ).style.merge(widget.style ?? Theme.of(context).textTheme.headlineMedium!);
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final maximum = base.fontSize ?? 28;
        final minimum = widget.minimumFontSize.clamp(1.0, maximum);
        double measure(double size) {
          final painter = TextPainter(
            text: TextSpan(
              text: widget.text,
              style: base.copyWith(fontSize: size),
            ),
            textDirection: direction,
            textScaler: scaler,
            locale: Localizations.maybeLocaleOf(context),
            maxLines: 1,
          )..layout();
          final result = painter.width;
          painter.dispose();
          return result;
        }

        var size = maximum;
        if (width.isFinite && measure(size) > width) {
          var lower = minimum;
          var upper = maximum;
          for (var i = 0; i < 12; i++) {
            final middle = (lower + upper) / 2;
            if (measure(middle) <= width) {
              lower = middle;
            } else {
              upper = middle;
            }
          }
          size = lower;
        }
        final textWidth = measure(size);
        final overflow = width.isFinite
            ? (textWidth - width).clamp(0.0, double.infinity)
            : 0.0;
        _configure((widget.text, width, size, textWidth, direction), overflow);
        return Semantics(
          label: widget.text,
          header: true,
          child: ExcludeSemantics(
            child: ClipRect(
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification is ScrollStartNotification &&
                      notification.dragDetails != null) {
                    _dragging = true;
                    _sync();
                  } else if (notification is ScrollEndNotification &&
                      _dragging) {
                    _dragging = false;
                    _sync();
                  }
                  return false;
                },
                child: SingleChildScrollView(
                  controller: _scroll,
                  scrollDirection: Axis.horizontal,
                  physics: overflow > 0
                      ? const ClampingScrollPhysics()
                      : const NeverScrollableScrollPhysics(),
                  child: Text(
                    widget.text,
                    maxLines: 1,
                    softWrap: false,
                    style: base.copyWith(fontSize: size),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
