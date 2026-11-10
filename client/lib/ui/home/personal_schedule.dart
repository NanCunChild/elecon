import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/schedule/calendar_export.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import 'models.dart';

ScheduleWeek withPersonalCourses(
  ScheduleWeek data,
  List<PersonalCourse> courses,
) {
  final start =
      scheduleDate(data.teachingWeekStart) ??
      scheduleDate(
        data.termStartDate,
      )?.add(Duration(days: (data.week - 1) * 7));
  if (start == null) return data;
  final matching = courses.where((e) {
    final date = scheduleDate(e.date)!;
    return !date.isBefore(start) &&
        date.isBefore(start.add(const Duration(days: 7)));
  }).toList();
  if (matching.isEmpty) return data;
  return ScheduleWeek(
    term: data.term,
    week: data.week,
    academicYear: data.academicYear,
    termStartDate: data.termStartDate,
    termEndDate: data.termEndDate,
    teachingWeekStart: data.teachingWeekStart,
    teachingWeekEnd: data.teachingWeekEnd,
    weekType: data.weekType,
    updatedAt: data.updatedAt,
    sourceSystem: data.sourceSystem,
    timeZone: data.timeZone,
    timeSegments: data.timeSegments,
    breakSegments: data.breakSegments,
    termWeeks: data.termWeeks,
    weekPreviews: data.weekPreviews,
    days: [
      for (var day = 1; day <= 7; day++)
        if (data.days.any((entry) => entry.dayOfWeek == day) ||
            matching.any((entry) => scheduleDate(entry.date)!.weekday == day))
          ScheduleWeekDays(
            dayOfWeek: day,
            slots: [
              ...data.days
                  .where((e) => e.dayOfWeek == day)
                  .expand((e) => e.slots),
              for (final course in matching)
                if (scheduleDate(course.date)!.weekday == day)
                  ScheduleWeekDaysSlots(
                    start: course.start,
                    end: course.end,
                    courseName: course.name,
                    courseId: 'personal:${course.id}',
                    date: course.date,
                    timeStart: course.start,
                    timeEnd: course.end,
                    location: course.location,
                  ),
            ],
          ),
    ],
  );
}

Future<void> showPersonalCourses(
  BuildContext context,
  SessionController session, {
  DateTime? initialDate,
}) async {
  final generation = session.trustedScriptViewGeneration;
  final school = session.selectedSchool?.id;
  bool active() =>
      context.mounted &&
      session.selectedSchool?.id == school &&
      session.trustedScriptViewGeneration == generation;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _PersonalCourses(
      session: session,
      active: active,
      initialDate: initialDate,
    ),
  );
}

class _PersonalCourses extends StatefulWidget {
  const _PersonalCourses({
    required this.session,
    required this.active,
    this.initialDate,
  });
  final SessionController session;
  final bool Function() active;
  final DateTime? initialDate;
  @override
  State<_PersonalCourses> createState() => _PersonalCoursesState();
}

class _PersonalCoursesState extends State<_PersonalCourses> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController(), _place = TextEditingController();
  late DateTime _date = widget.initialDate ?? DateTime.now();
  TimeOfDay _start = const TimeOfDay(hour: 8, minute: 30),
      _end = const TimeOfDay(hour: 10, minute: 5);
  String? _editing, _error;
  bool _busy = false;
  String _clock(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  @override
  void dispose() {
    _name.dispose();
    _place.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate() || _busy || !widget.active()) return;
    final l10n = AppLocalizations.of(context);
    if (_start.hour * 60 + _start.minute >= _end.hour * 60 + _end.minute) {
      setState(() => _error = l10n.scheduleInvalidTime);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id =
          _editing ??
          List.generate(
            16,
            (_) =>
                Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
          ).join();
      await widget.session.savePersonalCourse(
        PersonalCourse(
          id: id,
          name: _name.text.trim(),
          date: DateFormat('yyyy-MM-dd').format(_date),
          start: _clock(_start),
          end: _clock(_end),
          location: _place.text.trim(),
        ),
      );
      if (!mounted || !widget.active()) return;
      setState(() {
        _editing = null;
        _name.clear();
        _place.clear();
      });
    } catch (_) {
      if (mounted) setState(() => _error = l10n.scheduleSaveFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    List<PersonalCourse> courses = const [];
    try {
      courses = widget.session.personalCourses.toList()
        ..sort(
          (a, b) => '${a.date}${a.start}'.compareTo('${b.date}${b.start}'),
        );
    } catch (_) {
      _error = l10n.scheduleSaveFailed;
    }
    return FractionallySizedBox(
      heightFactor: .9,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          24,
          0,
          24,
          MediaQuery.viewInsetsOf(context).bottom + 24,
        ),
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.schedulePersonalCourses,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(l10n.schedulePersonalDescription),
              const SizedBox(height: 20),
              TextFormField(
                controller: _name,
                maxLength: 160,
                decoration: InputDecoration(labelText: l10n.scheduleCourseName),
                validator: (v) => v == null || v.trim().isEmpty
                    ? l10n.scheduleCourseRequired
                    : null,
              ),
              TextFormField(
                controller: _place,
                maxLength: 240,
                decoration: InputDecoration(
                  labelText: l10n.scheduleCourseLocation,
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.calendar_today_outlined),
                title: Text(
                  DateFormat.yMMMEd(
                    Localizations.localeOf(context).toString(),
                  ).format(_date),
                ),
                onTap: _busy
                    ? null
                    : () async {
                        final value = await showDatePicker(
                          context: context,
                          initialDate: _date,
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100),
                        );
                        if (mounted && value != null) {
                          setState(() => _date = value);
                        }
                      },
              ),
              Wrap(
                spacing: 12,
                children: [
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            final value = await showTimePicker(
                              context: context,
                              initialTime: _start,
                            );
                            if (mounted && value != null) {
                              setState(() => _start = value);
                            }
                          },
                    child: Text(
                      '${l10n.scheduleCourseStart} ${_start.format(context)}',
                    ),
                  ),
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            final value = await showTimePicker(
                              context: context,
                              initialTime: _end,
                            );
                            if (mounted && value != null) {
                              setState(() => _end = value);
                            }
                          },
                    child: Text(
                      '${l10n.scheduleCourseEnd} ${_end.format(context)}',
                    ),
                  ),
                ],
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _busy ? null : _save,
                icon: const Icon(Icons.save_outlined),
                label: Text(l10n.scheduleSaveCourse),
              ),
              const SizedBox(height: 16),
              for (final course in courses)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(course.name),
                  subtitle: Text(
                    '${course.date} · ${course.start}–${course.end}\n${course.location}',
                  ),
                  onTap: _busy
                      ? null
                      : () => setState(() {
                          _editing = course.id;
                          _name.text = course.name;
                          _place.text = course.location;
                          _date = scheduleDate(course.date)!;
                          _start = TimeOfDay(
                            hour: int.parse(course.start.substring(0, 2)),
                            minute: int.parse(course.start.substring(3)),
                          );
                          _end = TimeOfDay(
                            hour: int.parse(course.end.substring(0, 2)),
                            minute: int.parse(course.end.substring(3)),
                          );
                        }),
                  trailing: IconButton(
                    tooltip: l10n.commonDelete,
                    icon: const Icon(Icons.delete_outline),
                    onPressed: _busy
                        ? null
                        : () async {
                            if (!widget.active()) return;
                            setState(() => _busy = true);
                            try {
                              await widget.session.removePersonalCourse(
                                course.id,
                              );
                              if (mounted) {
                                setState(() {
                                  if (_editing == course.id) {
                                    _editing = null;
                                    _name.clear();
                                    _place.clear();
                                  }
                                });
                              }
                            } catch (_) {
                              if (mounted) {
                                setState(
                                  () => _error = l10n.scheduleSaveFailed,
                                );
                              }
                            } finally {
                              if (mounted) setState(() => _busy = false);
                            }
                          },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showScheduleExport(
  BuildContext context,
  ScheduleWeek schedule,
  List<PersonalCourse> personal,
  String sourceId,
) async {
  final l10n = AppLocalizations.of(context);
  final form = GlobalKey<FormState>();
  final minutes = TextEditingController(text: '10');
  var wholeTerm = false, reminder = false;
  final approved = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, update) => AlertDialog(
        title: Text(l10n.scheduleExport),
        content: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.scheduleExportDescription),
                const SizedBox(height: 12),
                if (schedule.termWeeks?.isNotEmpty ?? false)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.scheduleExportTerm),
                    value: wholeTerm,
                    onChanged: (v) => update(() => wholeTerm = v),
                  ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.scheduleClassReminder),
                  subtitle: Text(l10n.scheduleCalendarReminderDescription),
                  value: reminder,
                  onChanged: (v) => update(() => reminder = v),
                ),
                if (reminder)
                  TextFormField(
                    controller: minutes,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: l10n.scheduleReminderMinutes,
                    ),
                    validator: (v) {
                      final n = int.tryParse(v ?? '');
                      return n == null || n < 0 || n > 1440
                          ? l10n.scheduleReminderInvalid
                          : null;
                    },
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) Navigator.pop(ctx, true);
            },
            child: Text(l10n.scheduleExport),
          ),
        ],
      ),
    ),
  );
  final reminderMinutes = reminder ? int.tryParse(minutes.text) : null;
  // Dialog's closing animation can still reference the controller this frame.
  WidgetsBinding.instance.addPostFrameCallback((_) => minutes.dispose());
  if (approved != true || !context.mounted) return;
  try {
    final result = exportScheduleCalendar(
      schedule,
      sourceId: sourceId,
      wholeTerm: wholeTerm,
      personal: personal,
      reminderMinutes: reminderMinutes,
    );
    if (result.count == 0) {
      throw const FormatException('schedule_no_dated_courses');
    }
    final uri = await FilePicker.saveFile(
      fileName: 'elecon-schedule.ics',
      bytes: Uint8List.fromList(utf8.encode(result.text)),
      mimeType: 'text/calendar',
    );
    if (context.mounted && uri != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.scheduleExported(result.count, result.skipped)),
        ),
      );
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.scheduleExportFailed)));
    }
  }
}
