/// ADR-067: absolute intervals; uncovered time is unknown.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import '../../l10n/gen/app_localizations.dart';
import 'models.dart';

class ClassroomInterval {
  const ClassroomInterval(this.start, this.end, this.status, this.reason);
  final DateTime start;
  final DateTime end;
  final String status;
  final String? reason;
}

/// Reject contradictory data as a whole instead of painting false availability.
List<ClassroomInterval> classroomIntervals(ClassroomAvailableItems room) {
  final result = <ClassroomInterval>[];
  for (final item
      in room.intervals ?? const <ClassroomAvailableItemsIntervals>[]) {
    final offset = RegExp(r'(Z|[+-]\d{2}:\d{2})$');
    if (!offset.hasMatch(item.startAt) || !offset.hasMatch(item.endAt)) {
      return const [];
    }
    final start = DateTime.tryParse(item.startAt);
    final end = DateTime.tryParse(item.endAt);
    if (start == null ||
        end == null ||
        !end.isAfter(start) ||
        !const {'available', 'occupied', 'unknown'}.contains(item.status)) {
      return const [];
    }
    result.add(ClassroomInterval(start, end, item.status, item.reason));
  }
  result.sort((a, b) => a.start.compareTo(b.start));
  for (var i = 1; i < result.length; i++) {
    if (result[i].start.isBefore(result[i - 1].end)) return const [];
  }
  return result;
}

bool classroomAvailableDuring(
  ClassroomAvailableItems room,
  DateTime start,
  DateTime end,
) {
  if (!end.isAfter(start)) return false;
  var coveredUntil = start;
  for (final interval in classroomIntervals(room)) {
    if (!interval.end.isAfter(coveredUntil)) continue;
    if (interval.start.isAfter(coveredUntil) ||
        interval.status != 'available') {
      return false;
    }
    coveredUntil = interval.end;
    if (!coveredUntil.isBefore(end)) return true;
  }
  return false;
}

class ClassroomTimeline extends StatefulWidget {
  const ClassroomTimeline({super.key, required this.rooms, this.now});
  final List<ClassroomAvailableItems> rooms;

  /// Deterministic widget verification; production uses the device clock.
  final DateTime? now;

  @override
  State<ClassroomTimeline> createState() => _ClassroomTimelineState();
}

class _ClassroomTimelineState extends State<ClassroomTimeline> {
  Timer? _timer;
  DateTime? _start;
  DateTime? _end;
  bool _filter = false;
  String? _selected;

  @override
  void initState() {
    super.initState();
    if (widget.now == null) {
      _timer = Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(ClassroomTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Result/source replacement is a new query; never carry a previous range.
    if (oldWidget.rooms.isNotEmpty &&
        widget.rooms.isNotEmpty &&
        (oldWidget.rooms.first.buildingId != widget.rooms.first.buildingId ||
            oldWidget.rooms.first.intervals?.firstOrNull?.startAt !=
                widget.rooms.first.intervals?.firstOrNull?.startAt)) {
      _start = null;
      _end = null;
      _filter = false;
      _selected = null;
    }
  }

  Future<void> _pick(bool start, DateTime first, DateTime last) async {
    var previous = (start ? _start : _end) ?? first;
    // Room filtering may shrink the axis while this widget retains its state.
    if (previous.isBefore(first)) previous = first;
    if (previous.isAfter(last)) previous = last;
    var day = previous.toLocal();
    if (!DateUtils.isSameDay(first.toLocal(), last.toLocal())) {
      final picked = await showDatePicker(
        context: context,
        initialDate: day,
        firstDate: first.toLocal(),
        lastDate: last.toLocal(),
      );
      if (!mounted || picked == null) return;
      day = picked;
    }
    if (!mounted) return;
    final value = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(previous.toLocal()),
    );
    if (!mounted || value == null) return;
    final selected = DateTime(
      day.year,
      day.month,
      day.day,
      value.hour,
      value.minute,
    );
    setState(() {
      if (start) {
        _start = selected;
      } else {
        _end = selected;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final all = widget.rooms.expand(classroomIntervals).toList();
    if (all.isEmpty) return Text(l10n.classroomNoPreciseTimes);
    final axisStart = all
        .map((i) => i.start)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final axisEnd = all
        .map((i) => i.end)
        .reduce((a, b) => a.isAfter(b) ? a : b);
    final now = widget.now ?? DateTime.now();
    final total = axisEnd.difference(axisStart).inMilliseconds;
    double position(DateTime value) =>
        value.difference(axisStart).inMilliseconds / total;
    final validRange = _start != null && _end != null && _end!.isAfter(_start!);
    final rooms = _filter && validRange
        ? widget.rooms
              .where((room) => classroomAvailableDuring(room, _start!, _end!))
              .toList()
        : widget.rooms;
    String id(ClassroomAvailableItems room) =>
        room.roomId ?? '${room.building}/${room.room}';
    final selected =
        rooms.where((r) => id(r) == _selected).firstOrNull ?? rooms.firstOrNull;
    final format = DateFormat(
      'MM-dd HH:mm',
      Localizations.localeOf(context).toLanguageTag(),
    );
    String clock(DateTime time) => format.format(time.toLocal());
    String status(String value) => switch (value) {
      'available' => l10n.classroomAvailableStatus,
      'occupied' => l10n.classroomOccupiedStatus,
      _ => l10n.classroomUnknownStatus,
    };
    Color color(String value) => switch (value) {
      'available' => colors.primary,
      'occupied' => colors.error,
      _ => colors.outline,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.classroomCurrentTime(
            '${DateFormat('yyyy-MM-dd HH:mm', Localizations.localeOf(context).toLanguageTag()).format(now.toLocal())} ${now.toLocal().timeZoneName}',
          ),
        ),
        Text(
          l10n.classroomLocalTimeHint,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            OutlinedButton(
              onPressed: () => _pick(true, axisStart, axisEnd),
              child: Text(
                l10n.classroomStartTime(_start == null ? '—' : clock(_start!)),
              ),
            ),
            OutlinedButton(
              onPressed: () => _pick(false, axisStart, axisEnd),
              child: Text(
                l10n.classroomEndTime(_end == null ? '—' : clock(_end!)),
              ),
            ),
            FilterChip(
              label: Text(l10n.classroomOnlyFree),
              selected: _filter,
              onSelected: validRange
                  ? (v) => setState(() => _filter = v)
                  : null,
            ),
          ],
        ),
        if (_start != null && _end != null && !validRange)
          Text(
            l10n.classroomInvalidRange,
            style: TextStyle(color: colors.error),
          ),
        Wrap(
          spacing: 12,
          children: [
            for (final value in ['available', 'occupied', 'unknown'])
              Text('● ${status(value)}', style: TextStyle(color: color(value))),
          ],
        ),
        Directionality(
          textDirection: TextDirection.ltr,
          child: Padding(
            padding: const EdgeInsets.only(left: 100),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(child: Text(clock(axisStart))),
                Expanded(child: Text(clock(axisEnd), textAlign: TextAlign.end)),
              ],
            ),
          ),
        ),
        if (rooms.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(l10n.classroomNoRangeMatches),
          ),
        if (rooms.isNotEmpty)
          Directionality(
            // Time progresses left to right in every locale. Row labels and
            // absolute Positioned coordinates must use the same direction.
            textDirection: TextDirection.ltr,
            child: LayoutBuilder(
              builder: (context, constraints) {
                const nameWidth = 100.0;
                final width = (constraints.maxWidth - nameWidth).clamp(
                  1.0,
                  double.infinity,
                );
                final nowPosition = position(now);
                return Stack(
                  children: [
                    Column(
                      children: [
                        for (final room in rooms)
                          SizedBox(
                            height: 56,
                            child: Row(
                              children: [
                                SizedBox(
                                  width: nameWidth,
                                  child: TextButton(
                                    onPressed: () =>
                                        setState(() => _selected = id(room)),
                                    child: Text(
                                      room.room,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: SizedBox(
                                    height: 28,
                                    child: Stack(
                                      children: [
                                        Positioned.fill(
                                          child: ColoredBox(
                                            color:
                                                colors.surfaceContainerHighest,
                                          ),
                                        ),
                                        for (final interval
                                            in classroomIntervals(room))
                                          Positioned(
                                            left:
                                                position(interval.start) *
                                                width,
                                            width:
                                                (position(interval.end) -
                                                    position(interval.start)) *
                                                width,
                                            top: 0,
                                            bottom: 0,
                                            child: Tooltip(
                                              message:
                                                  '${clock(interval.start)}–${clock(interval.end)} · ${status(interval.status)}\n${interval.reason ?? l10n.classroomNoReason}',
                                              child: GestureDetector(
                                                onTap: () => setState(
                                                  () => _selected = id(room),
                                                ),
                                                child: Semantics(
                                                  label:
                                                      '${room.room} ${clock(interval.start)}–${clock(interval.end)} ${status(interval.status)}',
                                                  child: ColoredBox(
                                                    color: color(
                                                      interval.status,
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
                              ],
                            ),
                          ),
                      ],
                    ),
                    if (nowPosition >= 0 && nowPosition <= 1)
                      Positioned(
                        key: const ValueKey('classroom-current-time-line'),
                        left: nameWidth + nowPosition * width,
                        top: 0,
                        bottom: 0,
                        child: IgnorePointer(
                          child: Container(width: 2, color: colors.onSurface),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        if (selected != null) ...[
          const SizedBox(height: 8),
          Text(
            '${selected.building} ${selected.room}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          if (classroomIntervals(selected).isEmpty)
            Text(l10n.classroomNoPreciseTimes),
          for (final interval in classroomIntervals(selected))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text(
                '${clock(interval.start)}–${clock(interval.end)} · ${status(interval.status)}\n${interval.reason ?? l10n.classroomNoReason}',
              ),
            ),
        ],
      ],
    );
  }
}
