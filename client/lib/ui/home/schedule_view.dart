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
DateTime? _weekStart(ScheduleWeek data) {
  final explicit = DateTime.tryParse(data.teachingWeekStart ?? '');
  if (explicit != null) return explicit;
  final term = DateTime.tryParse(data.termStartDate ?? '');
  if (term != null) {
    return term
        .subtract(Duration(days: term.weekday - 1))
        .add(Duration(days: (data.week - 1) * 7));
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
        : _date(start.add(Duration(days: day.dayOfWeek - 1)));
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
  const ScheduleCard(this.data, {super.key, this.now});
  final ScheduleWeek data;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final page = HomeCardPresentation.maybeOf(context)?.isPage ?? false;
    if (page) return WeekScheduleView(data: data);
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
    return SectionCard(
      title: l10n.scheduleToday,
      subtitle:
          '${DateFormat.yMMMd(Localizations.localeOf(context).toString()).format(today)} · ${data.term} · ${l10n.scheduleWeekLabel(data.week)}',
      summary: CardSummary(
        slots.firstOrNull?.courseName ?? empty,
        detail: slots.isEmpty
            ? null
            : '${_time(slots.first)} · ${_place(slots.first)}',
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

/// Seven days share one time axis. Collisions occupy independent lanes.
class WeekScheduleView extends StatelessWidget {
  const WeekScheduleView({super.key, required this.data});
  final ScheduleWeek data;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final entries = [
      for (final day in data.days)
        for (final slot in day.slots)
          if (_inWeek(slot, data.week)) (day.dayOfWeek, slot),
    ];
    final timed =
        entries.isNotEmpty &&
        entries.every(
          (e) =>
              _minute(e.$2.timeStart) != null && _minute(e.$2.timeEnd) != null,
        );
    final placed = <(int, ScheduleWeekDaysSlots, int, int)>[];
    final other = <ScheduleWeekDaysSlots>[];
    for (final entry in entries) {
      final a = timed
          ? _minute(entry.$2.timeStart)
          : int.tryParse(entry.$2.start);
      final b = timed ? _minute(entry.$2.timeEnd) : int.tryParse(entry.$2.end);
      if (a == null ||
          b == null ||
          b < a ||
          (timed && b == a) ||
          (!timed && (a < 1 || b > 48))) {
        other.add(entry.$2);
      } else {
        placed.add((entry.$1, entry.$2, a, timed ? b : b + 1));
      }
    }
    final minimum = timed
        ? math.min(480, placed.map((e) => e.$3).fold(480, math.min)) ~/ 60 * 60
        : 1;
    final maximum = timed
        ? ((placed.map((e) => e.$4).fold(1080, math.max) + 59) ~/ 60) * 60
        : placed.map((e) => e.$4).fold(12, math.max);
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final unit = (timed ? 1.5 : 72.0) * math.max(1, scale);
    final height = (maximum - minimum) * unit;
    final start = _weekStart(data);
    final locale = Localizations.localeOf(context).toString();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${data.term} · ${l10n.scheduleWeekLabel(data.week)}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (data.sourceSystem != null) Text(data.sourceSystem!),
        if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(l10n.scheduleWeekEmpty),
          ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final columnWidth = math.max(
              48.0 * math.min(scale, 2),
              (constraints.maxWidth - 56) / 7,
            );
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: 56 + columnWidth * 7,
                child: Column(
                  children: [
                    Row(
                      children: [
                        const SizedBox(width: 56),
                        for (var day = 1; day <= 7; day++)
                          SizedBox(
                            width: columnWidth,
                            child: Padding(
                              padding: const EdgeInsets.all(6),
                              child: Text(
                                '${DateFormat.E(locale).format(DateTime(2024, 1, day))}${start == null ? '' : '\n${DateFormat.Md(locale).format(start.add(Duration(days: day - 1)))}'}',
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                      ],
                    ),
                    SizedBox(
                      height: height,
                      child: Stack(
                        children: [
                          for (
                            var t = minimum;
                            t < maximum;
                            t += timed ? 60 : 1
                          )
                            Positioned(
                              top: (t - minimum) * unit,
                              left: 0,
                              right: 0,
                              child: Container(
                                decoration: BoxDecoration(
                                  border: Border(
                                    top: BorderSide(
                                      color: colors.outlineVariant,
                                    ),
                                  ),
                                ),
                                child: Text(
                                  timed
                                      ? '${(t ~/ 60).toString().padLeft(2, '0')}:00'
                                      : '$t',
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                              ),
                            ),
                          for (var day = 1; day <= 7; day++)
                            ..._day(
                              context,
                              placed.where((e) => e.$1 == day).toList(),
                              day,
                              columnWidth,
                              minimum,
                              unit,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
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
    List<(int, ScheduleWeekDaysSlots, int, int)> slots,
    int day,
    double width,
    int minimum,
    double unit,
  ) {
    slots.sort((a, b) => a.$3.compareTo(b.$3));
    final ends = <int>[];
    final assigned = <((int, ScheduleWeekDaysSlots, int, int), int)>[];
    for (final slot in slots) {
      var lane = ends.indexWhere((end) => end <= slot.$3);
      if (lane < 0) {
        lane = ends.length;
        ends.add(slot.$4);
      } else {
        ends[lane] = slot.$4;
      }
      assigned.add((slot, lane));
    }
    final laneWidth = width / math.max(1, ends.length);
    final colors = Theme.of(context).colorScheme;
    return [
      for (final entry in assigned)
        Positioned(
          top: (entry.$1.$3 - minimum) * unit + 2,
          left: 56 + (day - 1) * width + entry.$2 * laneWidth + 2,
          width: laneWidth - 4,
          height: math.max(12, (entry.$1.$4 - entry.$1.$3) * unit - 4),
          child: Semantics(
            label:
                '${entry.$1.$2.courseName}, ${_time(entry.$1.$2)}, ${_place(entry.$1.$2)}',
            button: true,
            child: Material(
              color: entry.$1.$2.changeType == 'cancelled'
                  ? colors.surfaceContainerHighest
                  : colors.secondaryContainer,
              borderRadius: BorderRadius.circular(10),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => _details(context, entry.$1.$2),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text(
                    '${entry.$1.$2.courseName}\n${_place(entry.$1.$2)}\n${_time(entry.$1.$2)}',
                    overflow: TextOverflow.fade,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
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
