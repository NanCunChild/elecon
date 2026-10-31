/// Presentation only: stored RFC3339 timestamps remain unchanged.
String formatLocalDate(DateTime value) => _date(value.toLocal());

String formatLocalDateTime(DateTime value) {
  final local = value.toLocal();
  return '${_date(local)} ${_two(local.hour)}:${_two(local.minute)}';
}

String _date(DateTime value) =>
    '${value.year}-${_two(value.month)}-${_two(value.day)}';

String _two(int value) => value.toString().padLeft(2, '0');
