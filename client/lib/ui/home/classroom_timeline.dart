/// ADR-067: absolute intervals; uncovered time is unknown.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import '../../l10n/gen/app_localizations.dart';
import 'models.dart';

String classroomRoomAttributes(
  ClassroomAvailableItems room,
  AppLocalizations l10n,
) => [
  if (room.roomType != null) room.roomType!.label,
  if (room.floor != null) '${l10n.classroomFloor}: ${room.floor}',
  if (room.capacity != null) '${l10n.classroomCapacity}: ${room.capacity}',
  if (room.teachingCapacity != null)
    '${l10n.classroomTeachingCapacity}: ${room.teachingCapacity}',
  if (room.examCapacity != null)
    '${l10n.classroomExamCapacity}: ${room.examCapacity}',
].join(' · ');

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
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final all = widget.rooms.expand(classroomIntervals).toList();
    if (all.isEmpty) {
      return Column(
        children: [
          for (final room in widget.rooms)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${room.building} ${room.room}'),
              subtitle: Text(
                [
                  if (classroomRoomAttributes(room, l10n).isNotEmpty)
                    classroomRoomAttributes(room, l10n),
                  l10n.classroomNoPreciseTimes,
                ].join(' · '),
              ),
            ),
        ],
      );
    }
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
    final rooms = widget.rooms;
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
          spacing: 12,
          children: [
            for (final value in ['available', 'occupied', 'unknown'])
              Text('● ${status(value)}', style: TextStyle(color: color(value))),
          ],
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            final nameWidth = constraints.maxWidth < 400 ? 128.0 : 160.0;
            final width = (constraints.maxWidth - nameWidth).clamp(
              1.0,
              double.infinity,
            );
            double intervalWidth(ClassroomInterval interval) =>
                (position(interval.end) - position(interval.start)) * width;
            final labelFontSize =
                Theme.of(context).textTheme.labelSmall?.fontSize ?? 11;
            final minimumLabelWidth =
                36 *
                (MediaQuery.textScalerOf(context).scale(labelFontSize) /
                        labelFontSize)
                    .clamp(1.0, double.infinity);
            final nowPosition = position(now);
            return Directionality(
              textDirection: TextDirection.ltr,
              child: Column(
                children: [
                  Padding(
                    padding: EdgeInsets.only(left: nameWidth),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            clock(axisStart),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        Expanded(
                          child: Text(
                            clock(axisEnd),
                            textAlign: TextAlign.end,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Stack(
                    children: [
                      Column(
                        children: [
                          for (final room in rooms)
                            Padding(
                              key: ValueKey(
                                'classroom-row-${room.roomId ?? '${room.building}/${room.room}'}',
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: nameWidth,
                                    child: Padding(
                                      padding: const EdgeInsets.only(right: 12),
                                      child: Directionality(
                                        textDirection: Directionality.of(
                                          context,
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              '${room.building} ${room.room}',
                                              style: Theme.of(
                                                context,
                                              ).textTheme.titleSmall,
                                            ),
                                            if (classroomRoomAttributes(
                                              room,
                                              l10n,
                                            ).isNotEmpty)
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                  top: 3,
                                                ),
                                                child: Text(
                                                  classroomRoomAttributes(
                                                    room,
                                                    l10n,
                                                  ),
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall
                                                      ?.copyWith(
                                                        color: colors
                                                            .onSurfaceVariant,
                                                      ),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: classroomIntervals(room).isEmpty
                                        ? Text(
                                            l10n.classroomNoPreciseTimes,
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodySmall,
                                          )
                                        : SizedBox(
                                            height: 48,
                                            child: ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                              child: Stack(
                                                children: [
                                                  Positioned.fill(
                                                    child: ColoredBox(
                                                      color: colors
                                                          .surfaceContainerHighest,
                                                    ),
                                                  ),
                                                  for (final interval
                                                      in classroomIntervals(
                                                        room,
                                                      ))
                                                    Positioned(
                                                      left:
                                                          position(
                                                            interval.start,
                                                          ) *
                                                          width,
                                                      width: intervalWidth(
                                                        interval,
                                                      ),
                                                      top: 0,
                                                      bottom: 0,
                                                      child: Tooltip(
                                                        triggerMode:
                                                            TooltipTriggerMode
                                                                .tap,
                                                        message:
                                                            '${clock(interval.start)}–${clock(interval.end)} · ${status(interval.status)}\n${interval.reason ?? l10n.classroomNoReason}',
                                                        child: Semantics(
                                                          label:
                                                              '${room.building} ${room.room} ${clock(interval.start)}–${clock(interval.end)} ${status(interval.status)} ${interval.reason ?? l10n.classroomNoReason}',
                                                          child: DecoratedBox(
                                                            decoration: BoxDecoration(
                                                              color: switch (interval
                                                                  .status) {
                                                                'available' =>
                                                                  colors
                                                                      .primaryContainer,
                                                                'occupied' =>
                                                                  colors
                                                                      .errorContainer,
                                                                _ =>
                                                                  colors
                                                                      .surfaceContainerHighest,
                                                              },
                                                              border: Border(
                                                                right: BorderSide(
                                                                  color: colors
                                                                      .surface,
                                                                  width: 1,
                                                                ),
                                                              ),
                                                            ),
                                                            child:
                                                                intervalWidth(
                                                                      interval,
                                                                    ) <
                                                                    minimumLabelWidth
                                                                ? const SizedBox.expand()
                                                                : Padding(
                                                                    padding:
                                                                        const EdgeInsets.symmetric(
                                                                          horizontal:
                                                                              3,
                                                                        ),
                                                                    child: Center(
                                                                      child: Text(
                                                                        interval.status ==
                                                                                    'occupied' &&
                                                                                interval.reason?.trim().isNotEmpty ==
                                                                                    true
                                                                            ? interval.reason!
                                                                            : status(
                                                                                interval.status,
                                                                              ),
                                                                        maxLines:
                                                                            2,
                                                                        overflow:
                                                                            TextOverflow.ellipsis,
                                                                        textAlign:
                                                                            TextAlign.center,
                                                                        style:
                                                                            Theme.of(
                                                                              context,
                                                                            ).textTheme.labelSmall?.copyWith(
                                                                              color: switch (interval.status) {
                                                                                'available' => colors.onPrimaryContainer,
                                                                                'occupied' => colors.onErrorContainer,
                                                                                _ => colors.onSurfaceVariant,
                                                                              },
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
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}
