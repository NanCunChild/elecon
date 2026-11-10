part of 'session_controller.dart';

extension PersonalScheduleSession on SessionController {
  List<PersonalCourse> get personalCourses {
    _requireProtectedStoreAccess();
    final school = _school?.id;
    if (school == null) return const [];
    final entry = _store
        .list()
        .where(
          (e) => e.ref == 'personal-schedule:$school' && e.schoolId == school,
        )
        .firstOrNull;
    if (entry == null) return const [];
    final raw = jsonDecode(entry.value) as Map<String, dynamic>;
    if (raw['version'] != 1 ||
        raw['courses'] is! List ||
        (raw['courses'] as List).length > 256) {
      throw const FormatException('personal_schedule_invalid');
    }
    return List.unmodifiable(
      (raw['courses'] as List).map(
        (e) => PersonalCourse.fromJson(Map<String, dynamic>.from(e as Map)),
      ),
    );
  }

  Future<void> savePersonalCourse(PersonalCourse course) =>
      _editPersonalCourses((courses) {
        courses.removeWhere((old) => old.id == course.id);
        courses.add(course);
      });
  Future<void> removePersonalCourse(String id) =>
      _editPersonalCourses((courses) => courses.removeWhere((e) => e.id == id));

  Future<void> _editPersonalCourses(void Function(List<PersonalCourse>) edit) {
    final school = _school?.id;
    final store = _store;
    final backend = _secure;
    return _scripts.publish(() async {
      _requireProtectedStoreAccess();
      if (school == null ||
          _school?.id != school ||
          !identical(store, _store)) {
        throw StateError('script_cancelled');
      }
      final courses = personalCourses.toList();
      edit(courses);
      if (courses.length > 256) throw StateError('personal_schedule_limit');
      final ref = 'personal-schedule:$school';
      final previous = store.list().where((e) => e.ref == ref).firstOrNull;
      store.put(
        CredentialEntry(
          ref: ref,
          schoolId: school,
          type: 'personal-schedule',
          scope: const [],
          value: jsonEncode({
            'version': 1,
            'courses': courses.map((e) => e.toJson()).toList(),
          }),
          acquiredAt: DateTime.now().millisecondsSinceEpoch,
          expiresAt: null,
          status: CredentialStatus.active,
        ),
      );
      try {
        await _flushCredentialBackend(backend);
      } catch (_) {
        if (previous == null) {
          store.delete(ref);
        } else {
          store.put(previous);
        }
        rethrow;
      }
      if (!_scripts.disposed &&
          identical(store, _store) &&
          _school?.id == school) {
        onCredentialsChanged();
      }
    });
  }
}
