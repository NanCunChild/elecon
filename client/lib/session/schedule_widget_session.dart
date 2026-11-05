part of 'session_controller.dart';

extension ScheduleWidgetSession on SessionController {
  /// A display snapshot may persist only if the current identity uses H/S storage.
  bool get scheduleWidgetPersistence =>
      _secure is HardwareSecureStore || _secure is SoftwareSecureStore;

  /// Resolves only the explicitly approved source and returns opaque host metadata.
  /// The account token is removed in the same durable barrier as login caches.
  Future<String?> scheduleWidgetIdentity(
    String packageId,
    String digest,
  ) async {
    final school = _school?.id;
    final generation = trustedScriptViewGeneration;
    final dataGeneration = trustedScriptDataGeneration;
    final store = _store;
    final backend = _secure;
    if (!_isRestored || school == null || hardwareUnlockFailed) return null;
    final package = await _querySource(
      school,
      'schedule.week',
      packageId,
      digest,
    );
    bool current() =>
        !_scripts.disposed &&
        identical(store, _store) &&
        _school?.id == school &&
        trustedScriptViewGeneration == generation &&
        trustedScriptDataGeneration == dataGeneration;
    if (package == null || !current()) return null;
    try {
      final token = ScheduleWidgetIdentityStore(store).token(school);
      await _flushCredentialBackend(backend);
      return current() ? token : null;
    } catch (_) {
      return null;
    }
  }
}
