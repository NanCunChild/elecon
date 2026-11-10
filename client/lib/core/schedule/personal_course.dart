/// ADR-101: a user's local plan, independent of school script snapshots.
library;

class PersonalCourse {
  PersonalCourse({
    required this.id,
    required this.name,
    required this.date,
    required this.start,
    required this.end,
    this.location = '',
  }) {
    final parsed = DateTime.tryParse('${date}T00:00:00Z');
    final clock = RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$');
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
        name.trim().isEmpty ||
        name.length > 160 ||
        location.length > 240 ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) ||
        parsed == null ||
        !parsed.toIso8601String().startsWith(date) ||
        !clock.hasMatch(start) ||
        !clock.hasMatch(end) ||
        start.compareTo(end) >= 0) {
      throw const FormatException('personal_course_invalid');
    }
  }
  final String id, name, date, start, end, location;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'date': date,
    'start': start,
    'end': end,
    'location': location,
  };
  factory PersonalCourse.fromJson(Map<String, dynamic> json) => PersonalCourse(
    id: json['id'] as String,
    name: json['name'] as String,
    date: json['date'] as String,
    start: json['start'] as String,
    end: json['end'] as String,
    location: json['location'] as String? ?? '',
  );
}
