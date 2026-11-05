import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../l10n/gen/app_localizations.dart';
import 'card_layout.dart';
import 'models.dart';
import 'section_card.dart';

String _date(DateTime date) => DateFormat('yyyy-MM-dd').format(date);
String _time(ScheduleWeekDaysSlots s) =>
    '${s.timeStart ?? s.start}–${s.timeEnd ?? s.end}';
String _place(ScheduleWeekDaysSlots s) =>
    s.location ??
    [s.campus, s.building, s.room].whereType<String>().join(' · ');
bool _inWeek(ScheduleWeekDaysSlots s, int week) =>
    (s.weeks == null || s.weeks!.contains(week)) &&
    !(s.weekExceptions?.contains(week) ?? false);
DateTime _weekdayDate(DateTime start, int day) =>
    start.add(Duration(days: (day - start.weekday + 7) % 7));
DateTime? _weekStart(ScheduleWeek data) {
  final explicit = DateTime.tryParse(data.teachingWeekStart ?? '');
  if (explicit != null) return explicit;
  final term = DateTime.tryParse(data.termStartDate ?? '');
  if (term != null) {
    return term.add(Duration(days: (data.week - 1) * 7));
  }
  return null;
}

/// Unknown dates never make a historical weekday look like today's class.
List<ScheduleWeekDaysSlots> todaySlots(ScheduleWeek data, DateTime now) {
  final start = _weekStart(data);
  final today = _date(now);
  final result = <ScheduleWeekDaysSlots>[];
  for (final day in data.days) {
    final date = start == null
        ? null
        : _date(_weekdayDate(start, day.dayOfWeek));
    for (final slot in day.slots) {
      if ((slot.date ?? date) == today && _inWeek(slot, data.week)) {
        result.add(slot);
      }
    }
  }
  result.sort(
    (a, b) => (_minute(a.timeStart) ?? int.tryParse(a.start) ?? 9999).compareTo(
      _minute(b.timeStart) ?? int.tryParse(b.start) ?? 9999,
    ),
  );
  return result;
}

class ScheduleCard extends StatelessWidget {
  const ScheduleCard(
    this.data, {
    super.key,
    this.now,
    this.trailing,
    this.onWeekChanged,
    this.maxWeek = 25,
  });
  final ScheduleWeek data;
  final DateTime? now;
  final Widget? trailing;
  final ValueChanged<int>? onWeekChanged;
  final int maxWeek;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final page = HomeCardPresentation.maybeOf(context)?.isPage ?? false;
    if (page) {
      return WeekScheduleView(
        data: data,
        now: now,
        onWeekChanged: onWeekChanged,
        maxWeek: maxWeek,
      );
    }
    final today = now ?? DateTime.now();
    final slots = todaySlots(data, today);
    final knownDate =
        _weekStart(data) != null ||
        data.days.any((d) => d.slots.any((s) => s.date != null));
    final start = _weekStart(data);
    final currentWeek =
        start != null &&
        !DateTime(today.year, today.month, today.day).isBefore(start) &&
        today.isBefore(start.add(const Duration(days: 7)));
    final empty = !knownDate || (!currentWeek && slots.isEmpty)
        ? l10n.scheduleTodayUnavailable
        : l10n.scheduleTodayEmpty;
    final dateLabel = DateFormat.yMMMd(
      Localizations.localeOf(context).toString(),
    ).format(today);
    return SectionCard(
      title: l10n.scheduleToday,
      trailing: trailing,
      subtitle:
          '$dateLabel · ${data.term} · ${l10n.scheduleWeekLabel(data.week)}',
      summary: LayoutBuilder(
        builder: (context, constraints) {
          final courses = CardSummary(
            slots.firstOrNull?.courseName ?? empty,
            detail: slots.isEmpty
                ? null
                : '${_time(slots.first)} · ${_place(slots.first)}',
          );
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                dateLabel,
                key: const ValueKey('schedule-today-date'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(height: 4),
              if (constraints.hasBoundedHeight)
                Expanded(child: courses)
              else
                courses,
            ],
          );
        },
      ),
      child: slots.isEmpty
          ? Text(empty)
          : Column(
              children: [
                for (final slot in slots)
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: 72,
                          child: Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(
                              '${slot.timeStart ?? slot.start}\n${slot.timeEnd ?? slot.end}',
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                          ),
                        ),
                        Container(
                          width: 2,
                          margin: const EdgeInsets.symmetric(horizontal: 10),
                          color: Theme.of(context).colorScheme.primaryContainer,
                        ),
                        Expanded(
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 6,
                            ),
                            title: Text(slot.courseName),
                            subtitle: Text(
                              [_place(slot), slot.teacher, slot.changeReason]
                                  .whereType<String>()
                                  .where((s) => s.isNotEmpty)
                                  .join(' · '),
                            ),
                            onTap: () => _details(context, slot),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

int? _minute(String? text) {
  final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(text ?? '');
  if (match == null) return null;
  final h = int.parse(match[1]!), m = int.parse(match[2]!);
  return h < 24 && m < 60 ? h * 60 + m : null;
}

void _details(BuildContext context, ScheduleWeekDaysSlots slot) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              slot.courseName,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            for (final text in [
              slot.date,
              _time(slot),
              _place(slot),
              slot.teacher,
              slot.changeType,
              slot.changeReason,
            ])
              if (text != null && text.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(text),
                ),
          ],
        ),
      ),
    ),
  );
}

/// The horizontal strip scrolls independently of the full-width timetable.
class ScheduleWeekPicker extends StatefulWidget {
  const ScheduleWeekPicker({
    super.key,
    required this.week,
    required this.maxWeek,
    required this.onChanged,
    this.currentWeek,
    this.previews = const [],
    this.schedule,
    this.enabled = true,
  });

  final int week;
  final int maxWeek;
  final int? currentWeek;
  final ValueChanged<int> onChanged;
  final List<ScheduleWeekWeekPreviews> previews;
  final ScheduleWeek? schedule;
  final bool enabled;

  @override
  State<ScheduleWeekPicker> createState() => _ScheduleWeekPickerState();
}

class _ScheduleWeekPickerState extends State<ScheduleWeekPicker> {
  final _scroll = ScrollController();
  double _extent = 88;
  double? _viewport;

  @override
  void initState() {
    super.initState();
    _reveal(animate: false);
  }

  @override
  void didUpdateWidget(covariant ScheduleWeekPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.week != widget.week || oldWidget.maxWeek != widget.maxWeek) {
      _reveal();
    }
  }

  void _reveal({
    bool animate = true,
  }) => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted || !_scroll.hasClients) return;
    // Symmetric edge padding also allows the first/last week to be centered.
    final target = ((widget.week - 1) * _extent).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    if (!animate || MediaQuery.disableAnimationsOf(context)) {
      _scroll.jumpTo(target);
      return;
    }
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  });

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final extent = 88.0 * math.max(1.0, math.min(scale, 1.5));
    if (_extent != extent) _reveal(animate: false);
    _extent = extent;
    final previews = {for (final p in widget.previews) p.week: p};
    return SizedBox(
      height: 82 + 20 * math.max(1, scale),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (_viewport != constraints.maxWidth) {
            _viewport = constraints.maxWidth;
            _reveal(animate: false);
          }
          return ListView.builder(
            key: const ValueKey('schedule-week-strip'),
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            itemExtent: _extent,
            itemCount: widget.maxWeek,
            padding: EdgeInsets.symmetric(
              horizontal: math.max(0, (constraints.maxWidth - _extent) / 2),
            ),
            itemBuilder: (context, index) {
              final week = index + 1;
              final selected = week == widget.week;
              final current = week == widget.currentWeek;
              final preview = previews[week];
              final counts = <int?>[
                for (var day = 1; day <= 7; day++)
                  preview?.days
                      .where((d) => d.dayOfWeek == day)
                      .firstOrNull
                      ?.courseCount,
              ];
              final description = counts.any((c) => c == null)
                  ? l10n.schedulePreviewUnavailable
                  : l10n.schedulePreviewCourses(
                      counts.fold(0, (a, b) => a + b!),
                    );
              return Padding(
                padding: const EdgeInsets.all(4),
                child: Semantics(
                  selected: selected,
                  button: true,
                  label:
                      '${l10n.scheduleWeekLabel(week)}, ${current ? '${l10n.scheduleCurrentWeek}, ' : ''}$description',
                  child: Tooltip(
                    message: current
                        ? '${l10n.scheduleCurrentWeek} · $description'
                        : description,
                    child: Material(
                      key: current
                          ? ValueKey('schedule-current-week-$week')
                          : null,
                      color: selected
                          ? colors.primaryContainer
                          : colors.surfaceContainerLow,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: current
                              ? colors.primary
                              : colors.outlineVariant,
                          width: current ? 2 : 1,
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        key: ValueKey('schedule-week-$week'),
                        onTap: widget.enabled && !selected
                            ? () => widget.onChanged(week)
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Column(
                            children: [
                              Text(
                                l10n.scheduleWeekLabel(week),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 8),
                              Expanded(
                                child: ExcludeSemantics(
                                  child: CustomPaint(
                                    key: ValueKey('schedule-preview-$week'),
                                    size: const Size(
                                      double.infinity,
                                      double.infinity,
                                    ),
                                    painter: _WeekPreviewPainter(
                                      counts,
                                      _previewSpans(widget.schedule, week),
                                      selected
                                          ? colors.onPrimaryContainer
                                          : colors.primary,
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
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// Animate only the arriving week; a pending query never shows the previous
/// week's courses under the newly selected week label.
class ScheduleWeekTransition extends StatefulWidget {
  const ScheduleWeekTransition({
    super.key,
    required this.week,
    required this.child,
  });
  final int? week;
  final Widget child;

  @override
  State<ScheduleWeekTransition> createState() => _ScheduleWeekTransitionState();
}

class _ScheduleWeekTransitionState extends State<ScheduleWeekTransition>
    with SingleTickerProviderStateMixin {
  late final _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: 1,
  );
  int? _shownWeek;
  double _direction = 1;

  @override
  void initState() {
    super.initState();
    _shownWeek = widget.week;
  }

  @override
  void didUpdateWidget(covariant ScheduleWeekTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    final week = widget.week;
    if (week == null || week == _shownWeek) return;
    if (_shownWeek != null && !MediaQuery.disableAnimationsOf(context)) {
      _direction = week > _shownWeek! ? 1 : -1;
      _animation.forward(from: 0);
    }
    _shownWeek = week;
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = _animation.drive(CurveTween(curve: Curves.easeOutCubic));
    return ClipRect(
      child: FadeTransition(
        opacity: curve,
        child: SlideTransition(
          position: curve.drive(
            Tween(begin: Offset(.12 * _direction, 0), end: Offset.zero),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Known periods use their actual duration; older count-only previews retain
/// the density fallback and never invent a course's time.
List<({int day, double top, double bottom})>? _previewSpans(
  ScheduleWeek? data,
  int week,
) {
  if (data == null) return null;
  final terms = data.termWeeks
      ?.where((entry) => entry.week == week)
      .firstOrNull;
  if (terms == null && data.week != week) return null;
  final slots =
      <
        ({
          int day,
          String start,
          String end,
          String? timeStart,
          String? timeEnd,
        })
      >[
        if (terms != null) ...[
          for (final day in terms.days)
            for (final slot in day.slots)
              if ((slot.weeks == null || slot.weeks!.contains(week)) &&
                  !(slot.weekExceptions?.contains(week) ?? false) &&
                  slot.changeType != 'cancelled')
                (
                  day: day.dayOfWeek,
                  start: slot.start,
                  end: slot.end,
                  timeStart: slot.timeStart,
                  timeEnd: slot.timeEnd,
                ),
        ] else ...[
          for (final day in data.days)
            for (final slot in day.slots)
              if (_inWeek(slot, week) && slot.changeType != 'cancelled')
                (
                  day: day.dayOfWeek,
                  start: slot.start,
                  end: slot.end,
                  timeStart: slot.timeStart,
                  timeEnd: slot.timeEnd,
                ),
        ],
      ];
  final timed = slots.every(
    (s) => _minute(s.timeStart) != null && _minute(s.timeEnd) != null,
  );
  final positioned = <({int day, int start, int end})>[];
  for (final slot in slots) {
    final start = timed ? _minute(slot.timeStart) : int.tryParse(slot.start);
    final end = timed ? _minute(slot.timeEnd) : int.tryParse(slot.end);
    if (start == null ||
        end == null ||
        slot.day < 1 ||
        slot.day > 7 ||
        end < start ||
        (timed && end == start)) {
      return null;
    }
    positioned.add((day: slot.day, start: start, end: timed ? end : end + 1));
  }
  final min = positioned.map((s) => s.start).fold(timed ? 480 : 1, math.min);
  final max = positioned.map((s) => s.end).fold(timed ? 1080 : 13, math.max);
  return [
    for (final slot in positioned)
      (
        day: slot.day,
        top: (slot.start - min) / (max - min),
        bottom: (slot.end - min) / (max - min),
      ),
  ];
}

class _WeekPreviewPainter extends CustomPainter {
  const _WeekPreviewPainter(this.counts, this.spans, this.color);
  final List<({int day, double top, double bottom})>? spans;
  final List<int?> counts;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / 7;
    if (spans != null) {
      for (var day = 0; day < 7; day++) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              day * cell + 1,
              0,
              math.max(1, cell - 2),
              size.height,
            ),
            const Radius.circular(2),
          ),
          Paint()..color = color.withValues(alpha: .12),
        );
      }
      for (final span in spans!) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              (span.day - 1) * cell + 1,
              span.top * size.height,
              math.max(1, cell - 2),
              math.max(2, (span.bottom - span.top) * size.height),
            ),
            const Radius.circular(2),
          ),
          Paint()..color = color.withValues(alpha: .85),
        );
      }
      return;
    }
    for (var day = 0; day < 7; day++) {
      final count = counts[day];
      if (count == null) {
        canvas.drawLine(
          Offset((day + .25) * cell, size.height / 2),
          Offset((day + .75) * cell, size.height / 2),
          Paint()
            ..color = color.withValues(alpha: .4)
            ..strokeWidth = 1.5,
        );
      } else {
        for (var row = 0; row < 4; row++) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(
                day * cell + 1,
                (3 - row) * size.height / 4 + 1,
                math.max(1, cell - 2),
                math.max(1, size.height / 4 - 2),
              ),
              const Radius.circular(2),
            ),
            Paint()..color = color.withValues(alpha: row < count ? .85 : .12),
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _WeekPreviewPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.spans.toString() != spans.toString() ||
      oldDelegate.counts.toString() != counts.toString();
}

typedef _PlacedCourse = ({
  int day,
  ScheduleWeekDaysSlots slot,
  int start,
  int end,
});

/// Seven fixed-width day columns. Overlapping events share the entire column.
class WeekScheduleView extends StatelessWidget {
  const WeekScheduleView({
    super.key,
    required this.data,
    this.now,
    this.onWeekChanged,
    this.maxWeek = 25,
  });
  final ScheduleWeek data;
  final DateTime? now;
  final ValueChanged<int>? onWeekChanged;
  final int maxWeek;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final entries = [
      for (final day in data.days)
        for (final slot in day.slots)
          if (_inWeek(slot, data.week)) (day.dayOfWeek, slot),
    ];
    final timed = entries.isEmpty
        ? (data.timeSegments?.isNotEmpty ?? false)
        : entries.every(
            (e) =>
                _minute(e.$2.timeStart) != null &&
                _minute(e.$2.timeEnd) != null,
          );
    final placed = <_PlacedCourse>[];
    final other = <ScheduleWeekDaysSlots>[];
    for (final entry in entries) {
      final a = timed
          ? _minute(entry.$2.timeStart)
          : int.tryParse(entry.$2.start);
      final b = timed ? _minute(entry.$2.timeEnd) : int.tryParse(entry.$2.end);
      if (entry.$1 < 1 ||
          entry.$1 > 7 ||
          a == null ||
          b == null ||
          b < a ||
          (timed && b == a) ||
          (!timed && (a < 1 || b > 48))) {
        other.add(entry.$2);
      } else {
        placed.add((
          day: entry.$1,
          slot: entry.$2,
          start: a,
          end: timed ? b : b + 1,
        ));
      }
    }
    final scale = math.max(
      1.0,
      MediaQuery.textScalerOf(context).scale(14) / 14,
    );
    final axis = _ScheduleAxis(
      placed,
      timed,
      data.timeSegments,
      data.breakSegments,
      scale,
    );
    final conflicts = placed
        .where((e) => placed.any((o) => o != e && _overlaps(e, o)))
        .length;
    final start = _weekStart(data);
    final today = now ?? DateTime.now();
    final locale = Localizations.localeOf(context).toString();
    final grid = LayoutBuilder(
      builder: (context, constraints) {
        final axisWidth = math.min(46.0, constraints.maxWidth * .18);
        final columnWidth = math.max(
          0.0,
          (constraints.maxWidth - axisWidth) / 7,
        );
        return SizedBox(
          key: const ValueKey('schedule-grid'),
          width: constraints.maxWidth,
          child: Column(
            children: [
              Row(
                children: [
                  SizedBox(width: axisWidth),
                  for (var day = 1; day <= 7; day++)
                    SizedBox(
                      width: columnWidth,
                      height: 48 * math.min(scale, 1.5),
                      child: _ScheduleDayHeader(
                        day: day,
                        date: start == null ? null : _weekdayDate(start, day),
                        today: today,
                        locale: locale,
                      ),
                    ),
                ],
              ),
              SizedBox(
                height: axis.height,
                child: Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    for (var index = 0; index < axis.breaks.length; index++)
                      for (var day = 1; day <= 7; day++)
                        if (data.days.any((known) => known.dayOfWeek == day) &&
                            !placed.any(
                              (course) =>
                                  course.day == day &&
                                  course.start < axis.breaks[index].$2 &&
                                  course.end > axis.breaks[index].$1,
                            ))
                          Positioned(
                            top: axis.y(axis.breaks[index].$1),
                            left: axisWidth + (day - 1) * columnWidth,
                            width: columnWidth,
                            height:
                                axis.y(axis.breaks[index].$2) -
                                axis.y(axis.breaks[index].$1),
                            child: _ScheduleBreak(
                              key: ValueKey('schedule-break-$day-$index'),
                              label: axis.breaks[index].$3,
                              time:
                                  '${_clock(axis.breaks[index].$1)}–${_clock(axis.breaks[index].$2)}',
                            ),
                          ),
                    for (final tick in axis.ticks)
                      Positioned(
                        top: axis.y(tick.$1),
                        left: 0,
                        right: 0,
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border(
                              top: BorderSide(color: colors.outlineVariant),
                            ),
                          ),
                          alignment: Alignment.topLeft,
                          child: SizedBox(
                            width: axisWidth - 3,
                            child: FittedBox(
                              alignment: Alignment.topLeft,
                              fit: BoxFit.scaleDown,
                              child: Text(
                                tick.$2,
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                            ),
                          ),
                        ),
                      ),
                    for (var day = 1; day <= 7; day++)
                      ..._day(
                        context,
                        placed.where((e) => e.day == day).toList(),
                        columnWidth,
                        axisWidth,
                        axis,
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${data.term} · ${l10n.scheduleWeekLabel(data.week)}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (data.sourceSystem != null) Text(data.sourceSystem!),
        if (conflicts > 0)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.layers_outlined, size: 18, color: colors.tertiary),
                const SizedBox(width: 6),
                Expanded(child: Text(l10n.scheduleOverlapHint(conflicts))),
              ],
            ),
          ),
        if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(l10n.scheduleWeekEmpty),
          ),
        const SizedBox(height: 12),
        _WeekSwipeArea(
          onChanged: onWeekChanged,
          week: data.week,
          maxWeek: maxWeek,
          child: grid,
        ),
        for (final slot in other)
          ListTile(
            title: Text(slot.courseName),
            subtitle: Text(_time(slot)),
            onTap: () => _details(context, slot),
          ),
      ],
    );
  }

  List<Widget> _day(
    BuildContext context,
    List<_PlacedCourse> slots,
    double width,
    double axisWidth,
    _ScheduleAxis axis,
  ) {
    slots.sort((a, b) => a.start.compareTo(b.start));
    final colors = Theme.of(context).colorScheme;
    return [
      for (var index = 0; index < slots.length; index++)
        Positioned(
          top: axis.y(slots[index].start) + 2,
          left: axisWidth + (slots[index].day - 1) * width + 1,
          width: math.max(0, width - 2),
          height: math.max(
            18,
            axis.y(slots[index].end) - axis.y(slots[index].start) - 4,
          ),
          child: Semantics(
            label:
                '${slots[index].slot.courseName}, ${_time(slots[index].slot)}, ${_place(slots[index].slot)}',
            button: true,
            child: Material(
              key: ValueKey('schedule-course-${slots[index].day}-$index'),
              color: slots[index].slot.changeType == 'cancelled'
                  ? colors.surfaceContainerHighest
                  : colors.secondaryContainer,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(7),
                side: BorderSide(color: colors.outlineVariant),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => _openCourse(context, slots[index], slots),
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Text(
                    '${slots[index].slot.courseName}\n${_place(slots[index].slot)}\n${_time(slots[index].slot)}',
                    overflow: TextOverflow.fade,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colors.onSecondaryContainer,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
    ];
  }
}

class _ScheduleDayHeader extends StatelessWidget {
  const _ScheduleDayHeader({
    required this.day,
    required this.date,
    required this.today,
    required this.locale,
  });
  final int day;
  final DateTime? date;
  final DateTime today;
  final String locale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = date != null && DateUtils.isSameDay(date, today);
    final label =
        '${DateFormat.E(locale).format(DateTime(2024, 1, day))}${date == null ? '' : '\n${DateFormat.Md(locale).format(date!)}'}';
    return Semantics(
      label: current
          ? '${MaterialLocalizations.of(context).currentDateLabel}, $label'
          : label,
      excludeSemantics: true,
      child: Container(
        key: ValueKey('schedule-day-$day'),
        margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          color: current ? theme.colorScheme.primaryContainer : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: current ? theme.colorScheme.onPrimaryContainer : null,
              fontWeight: current ? FontWeight.w700 : null,
            ),
          ),
        ),
      ),
    );
  }
}

bool _overlaps(_PlacedCourse a, _PlacedCourse b) =>
    a.day == b.day && a.start < b.end && b.start < a.end;

void _openCourse(
  BuildContext context,
  _PlacedCourse selected,
  List<_PlacedCourse> day,
) {
  final group = <_PlacedCourse>{selected};
  var changed = true;
  while (changed) {
    changed = false;
    for (final course in day) {
      if (!group.contains(course) &&
          group.any((member) => _overlaps(member, course))) {
        group.add(course);
        changed = true;
      }
    }
  }
  if (group.length == 1) {
    _details(context, selected.slot);
    return;
  }
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              AppLocalizations.of(context).scheduleOverlappingCourses,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            for (final course in group)
              ListTile(
                title: Text(course.slot.courseName),
                subtitle: Text(
                  '${_time(course.slot)} · ${_place(course.slot)}',
                ),
                onTap: () => _details(sheetContext, course.slot),
              ),
          ],
        ),
      ),
    ),
  );
}

class _ScheduleBreak extends StatelessWidget {
  const _ScheduleBreak({super.key, required this.label, required this.time});

  final String label;
  final String time;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final description = AppLocalizations.of(
      context,
    ).scheduleBreakNoClasses(label, time);
    return Semantics(
      label: description,
      child: Tooltip(
        message: description,
        excludeFromSemantics: true,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            border: Border.symmetric(
              horizontal: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Center(
              child: ExcludeSemantics(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ScheduleAxis {
  _ScheduleAxis(
    List<_PlacedCourse> courses,
    bool timed,
    List<ScheduleWeekTimeSegments>? segments,
    List<ScheduleWeekBreakSegments>? restSegments,
    double scale,
  ) {
    final minimum = timed
        ? math.min(480, courses.map((e) => e.start).fold(480, math.min)) ~/
              60 *
              60
        : 1;
    final maximum = timed
        ? ((courses.map((e) => e.end).fold(1080, math.max) + 59) ~/ 60) * 60
        : courses.map((e) => e.end).fold(12, math.max);
    final valid = <(int, int, String)>[];
    var previousEnd = -1;
    for (final segment in segments ?? <ScheduleWeekTimeSegments>[]) {
      final start = _minute(segment.timeStart), end = _minute(segment.timeEnd);
      if (start == null ||
          end == null ||
          end <= start ||
          start < previousEnd ||
          segment.label.isEmpty ||
          segment.label.length > 40 ||
          segments!.length > 48) {
        valid.clear();
        break;
      }
      valid.add((start, end, segment.label));
      previousEnd = end;
    }
    if (timed && valid.isNotEmpty) {
      previousEnd = -1;
      for (final rest in restSegments ?? <ScheduleWeekBreakSegments>[]) {
        final start = _minute(rest.timeStart), end = _minute(rest.timeEnd);
        if (start == null ||
            end == null ||
            end <= start ||
            start < previousEnd ||
            rest.label.isEmpty ||
            rest.label.length > 40 ||
            restSegments!.length > 16 ||
            valid.any((lesson) => start < lesson.$2 && end > lesson.$1)) {
          breaks.clear();
          break;
        }
        breaks.add((start, end, rest.label));
        previousEnd = end;
      }
      // School data owns the outer bounds too. Host fallback hours apply only
      // when school time segments are unavailable, never as extra school hours.
      final low = [
        valid.first.$1,
        for (final c in courses) c.start,
        for (final rest in breaks) rest.$1,
      ].reduce(math.min);
      final high = [
        valid.last.$2,
        for (final c in courses) c.end,
        for (final rest in breaks) rest.$2,
      ].reduce(math.max);
      final stops = {
        low,
        high,
        for (final s in valid) ...[s.$1, s.$2],
        for (final rest in breaks) ...[rest.$1, rest.$2],
      }.toList()..sort();
      for (var i = 0; i < stops.length - 1; i++) {
        final a = stops[i], b = stops[i + 1];
        final teaching = valid.any((s) => a >= s.$1 && b <= s.$2);
        final occupied = courses.any((c) => c.start < b && c.end > a);
        final rest = breaks.any((s) => a >= s.$1 && b <= s.$2);
        final extent = teaching
            ? 72.0 * scale
            : occupied
            ? math.max(48.0, (b - a) * 1.2) * scale
            : rest
            ? 24.0 * scale
            : 12.0 * scale;
        _pieces.add((a, b, extent));
      }
      ticks.addAll(
        valid.map((s) => (s.$1, '${s.$3}\n${_clock(s.$1)}\n${_clock(s.$2)}')),
      );
      for (final c in courses) {
        if (!valid.any((s) => c.start >= s.$1 && c.start < s.$2)) {
          ticks.add((c.start, _clock(c.start)));
        }
      }
    } else {
      _pieces.add((
        minimum,
        maximum,
        (maximum - minimum) * (timed ? 1.5 : 72.0) * scale,
      ));
      for (var t = minimum; t < maximum; t += timed ? 60 : 1) {
        ticks.add((t, timed ? _clock(t) : '$t'));
      }
    }
  }

  final _pieces = <(int, int, double)>[];
  final ticks = <(int, String)>[];
  final breaks = <(int, int, String)>[];
  double get height => _pieces.fold(0, (sum, p) => sum + p.$3);
  double y(int value) {
    var result = 0.0;
    for (final piece in _pieces) {
      if (value <= piece.$1) return result;
      if (value < piece.$2) {
        return result + (value - piece.$1) / (piece.$2 - piece.$1) * piece.$3;
      }
      result += piece.$3;
    }
    return result;
  }
}

String _clock(int minute) =>
    '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';

class _WeekSwipeArea extends StatefulWidget {
  const _WeekSwipeArea({
    required this.child,
    required this.week,
    required this.maxWeek,
    this.onChanged,
  });
  final Widget child;
  final int week;
  final int maxWeek;
  final ValueChanged<int>? onChanged;
  @override
  State<_WeekSwipeArea> createState() => _WeekSwipeAreaState();
}

class _WeekSwipeAreaState extends State<_WeekSwipeArea> {
  double _distance = 0;
  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onHorizontalDragStart: widget.onChanged == null
        ? null
        : (_) => _distance = 0,
    onHorizontalDragUpdate: widget.onChanged == null
        ? null
        : (d) => _distance += d.delta.dx,
    onHorizontalDragEnd: widget.onChanged == null
        ? null
        : (d) {
            final velocity = d.primaryVelocity ?? 0;
            if (_distance.abs() < 40 && velocity.abs() < 250) return;
            final direction = _distance.abs() >= 40 ? _distance : velocity;
            final next = widget.week + (direction < 0 ? 1 : -1);
            if (next >= 1 && next <= widget.maxWeek) widget.onChanged!(next);
          },
    child: widget.child,
  );
}
