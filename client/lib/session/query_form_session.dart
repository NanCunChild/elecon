/// ADR-091: expose only scoped form data, never the credential backend.
part of 'session_controller.dart';

extension QueryFormSession on SessionController {
  Future<Map<String, dynamic>?> cachedQueryForm(
    String packageId,
    String digest,
    String target,
    Map<String, dynamic> params, {
    bool draft = false,
  }) async {
    final school = _school?.id;
    final generation = _scripts.generation;
    final dataGeneration = _scripts.dataGeneration;
    final locale = scriptLocale;
    if (school == null || _scripts.disposed) return null;
    try {
      final package = await _querySource(school, target, packageId, digest);
      if (package == null ||
          _school?.id != school ||
          _scripts.generation != generation ||
          _scripts.dataGeneration != dataGeneration ||
          scriptLocale != locale) {
        return null;
      }
      return ScriptQueryFormCache(
        _store,
        locale: locale,
      ).read(package, target, params, draft: draft);
    } on Object {
      return null;
    }
  }

  Future<bool> saveQueryForm(
    String packageId,
    String digest,
    String target,
    Map<String, dynamic> params,
    Map<String, dynamic>? data, {
    bool draft = false,
  }) async {
    final school = _school?.id;
    final generation = _scripts.generation;
    final dataGeneration = _scripts.dataGeneration;
    final locale = scriptLocale;
    final store = _store;
    final backend = _secure;
    if (school == null || _scripts.disposed) return false;
    bool active() =>
        !_scripts.disposed &&
        _school?.id == school &&
        _scripts.generation == generation &&
        _scripts.dataGeneration == dataGeneration &&
        scriptLocale == locale &&
        identical(store, _store);
    try {
      final package = await _querySource(school, target, packageId, digest);
      if (package == null || !active()) return false;
      if (!ScriptQueryFormCache(
        store,
        locale: locale,
      ).write(package, target, params, data, draft: draft)) {
        return false;
      }
      await _flushCredentialBackend(backend);
      return active();
    } on Object {
      return false;
    }
  }
}
