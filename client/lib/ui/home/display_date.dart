import '../../l10n/gen/app_localizations.dart';

/// Presentation only: stored RFC3339 timestamps remain unchanged.
String formatLocalDate(DateTime value) => _date(value.toLocal());

String formatLocalDateTime(DateTime value) {
  final local = value.toLocal();
  return '${_date(local)} ${_two(local.hour)}:${_two(local.minute)}';
}

String _date(DateTime value) =>
    '${value.year}-${_two(value.month)}-${_two(value.day)}';

String _two(int value) => value.toString().padLeft(2, '0');

/// Use elapsed time for freshness, without altering stored timestamps or TTLs.
String formatUpdateTime(
  DateTime value,
  AppLocalizations l10n, {
  DateTime? now,
}) {
  final age = (now ?? DateTime.now()).difference(value);
  // A future timestamp may indicate clock skew; do not call it a fresh update.
  if (age.isNegative || age > const Duration(days: 3)) {
    return formatLocalDate(value);
  }
  if (age.inMinutes == 0) return l10n.homeTimeJustNow;
  if (age.inHours == 0) return l10n.homeTimeMinutesAgo(age.inMinutes);
  return l10n.homeTimeHoursAgo(age.inHours);
}
