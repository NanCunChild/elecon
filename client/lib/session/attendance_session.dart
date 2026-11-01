/// ADR-055: narrow UI access to locations for the approved, selected provider.
part of 'session_controller.dart';

extension AttendanceSession on SessionController {
  bool _placesProviderActive(
    ScriptRegistry registry,
    ScriptPackage package,
    int generation,
  ) =>
      !_scripts.disposed &&
      _scripts.generation == generation &&
      _school?.id == package.manifest.schoolId &&
      package.manifest.capability('attendance.checkin')?.schemaVersion ==
          '1.1' &&
      registry.find(package.manifest.id)?.enabled == true &&
      registry.find(package.manifest.id)?.package.digest == package.digest;

  Future<List<AttendancePlace>> attendancePlaces(ScriptPackage package) async {
    final generation = _scripts.generation;
    final registry = await scriptRegistry;
    if (!_placesProviderActive(registry, package, generation)) return const [];
    return AttendancePlacesStore(
      _store,
    ).read(package.manifest.schoolId, package.manifest.id);
  }

  Future<void> saveAttendancePlaces(
    ScriptPackage package,
    List<AttendancePlace> places,
  ) async {
    final generation = _scripts.generation;
    final registry = await scriptRegistry;
    if (!_placesProviderActive(registry, package, generation)) {
      throw StateError('attendance_provider_changed');
    }
    await ensurePersistentStore(
      confirmSoftwareFallback: _scripts.storageConsent ?? () async => false,
    );
    if (!_placesProviderActive(registry, package, generation)) {
      throw StateError('attendance_provider_changed');
    }
    final store = _store;
    final backend = _secure;
    final locations = AttendancePlacesStore(store);
    final school = package.manifest.schoolId;
    final provider = package.manifest.id;
    final previous = locations.read(school, provider);
    try {
      locations.write(school, provider, List.of(places));
      await _flushCredentialBackend(backend);
    } catch (_) {
      if (identical(store, _store) &&
          _placesProviderActive(registry, package, generation)) {
        locations.write(school, provider, previous);
      }
      rethrow;
    }
    if (!_placesProviderActive(registry, package, generation)) {
      throw StateError('attendance_provider_changed');
    }
  }
}
