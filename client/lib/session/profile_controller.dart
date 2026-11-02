/// ADR-044: independent sessions and storage; UI only sees session metadata.
library;

import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../core/credential/blob_store.dart';
import 'session_controller.dart';

class SessionProfile {
  SessionProfile._(this.id, this.name, this.session);
  final String id;
  final String name;
  final SessionController session;
}

typedef ProfileSessionFactory = SessionController Function(BlobStore? blobs);

class ProfileController extends ChangeNotifier {
  ProfileController({
    required this.createSession,
    this.blobStoreProvider,
    SessionController? initialSession,
  }) {
    _profiles.add(
      SessionProfile._(
        'default',
        'Profile 1',
        initialSession ?? createSession(null),
      ),
    );
  }

  final ProfileSessionFactory createSession;
  final Future<BlobStore?> Function()? blobStoreProvider;
  final List<SessionProfile> _profiles = [];
  BlobStore? _blobs;
  String _activeId = 'default';
  Future<void>? _bootstrap;
  bool _busy = false;
  bool _isRestored = false;
  bool get isRestored => _isRestored;
  bool get busy => _busy;
  List<SessionProfile> get profiles => List.unmodifiable(_profiles);
  SessionProfile get active => _profiles.firstWhere((p) => p.id == _activeId);

  Future<void> bootstrap() => _bootstrap ??= _load();

  Future<void> _load() async {
    _blobs = await blobStoreProvider?.call();
    final raw = await _blobs?.read('profiles.json');
    if (raw != null) {
      if (raw.length > 65536) {
        throw const FormatException('profile index too large');
      }
      final value = jsonDecode(utf8.decode(raw));
      if (value is! Map ||
          value['version'] != 1 ||
          value['profiles'] is! List) {
        throw const FormatException('invalid profile index');
      }
      final rows = value['profiles'] as List;
      if (rows.isEmpty || rows.length > 32) {
        throw const FormatException('invalid profiles');
      }
      final ids = <String>{};
      final restored = <SessionProfile>[];
      for (final row in rows) {
        if (row is! Map || row['id'] is! String || row['name'] is! String) {
          throw const FormatException('invalid profile');
        }
        final id = row['id'] as String;
        final name = row['name'] as String;
        if (!(id == 'default' || RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) ||
            !ids.add(id) ||
            name.trim().isEmpty ||
            name.length > 80) {
          throw const FormatException('invalid profile');
        }
        restored.add(SessionProfile._(id, name, createSession(_storage(id))));
      }
      if (!ids.contains('default') || !ids.contains(value['activeId'])) {
        throw const FormatException('invalid active profile');
      }
      for (final p in _profiles) {
        p.session.dispose();
      }
      _profiles
        ..clear()
        ..addAll(restored);
      _activeId = value['activeId'] as String;
    } else if (_blobs != null) {
      // Existing root storage belongs only to the migration Profile.
      final old = _profiles.single;
      old.session.dispose();
      _profiles[0] = SessionProfile._(
        'default',
        old.name,
        createSession(_blobs),
      );
      await _persist(_profiles, _activeId);
    }
    // ADR-060: inactive identities neither unlock their stores nor load
    // school runtimes until the user selects them.
    await active.session.bootstrap();
    _isRestored = true;
    for (final p in _profiles) {
      p.session.addListener(_changed);
    }
    notifyListeners();
  }

  BlobStore? _storage(String id) => _blobs == null
      ? null
      : id == 'default'
      ? _blobs
      : _ProfileBlobs(_blobs!, id);

  void _changed() => notifyListeners();

  Future<void> _persist(List<SessionProfile> profiles, String activeId) async {
    await _blobs?.write(
      'profiles.json',
      utf8.encode(
        jsonEncode({
          'version': 1,
          'activeId': activeId,
          'profiles': [
            for (final p in profiles) {'id': p.id, 'name': p.name},
          ],
        }),
      ),
    );
  }

  Future<void> activate(String id) async {
    if (id == _activeId) return;
    if (_busy) throw StateError('profile_busy');
    final next = _profiles.firstWhere((p) => p.id == id);
    _busy = true;
    notifyListeners();
    try {
      active.session.cancelTrustedScriptRuns();
      await active.session.flush();
      await next.session.bootstrap();
      await _persist(_profiles, id);
      _activeId = id;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> add() async {
    if (_busy || _profiles.length >= 32) throw StateError('profile_limit');
    _busy = true;
    notifyListeners();
    SessionProfile? added;
    try {
      active.session.cancelTrustedScriptRuns();
      await active.session.flush();
      final random = Random.secure();
      final id = List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      added = SessionProfile._(
        id,
        'Profile ${_profiles.length + 1}',
        createSession(_storage(id)),
      );
      await added.session.bootstrap();
      await _persist([..._profiles, added], id);
      added.session.addListener(_changed);
      _profiles.add(added);
      _activeId = id;
    } catch (_) {
      added?.session.dispose();
      rethrow;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    for (final p in _profiles) {
      p.session.removeListener(_changed);
      p.session.dispose();
    }
    super.dispose();
  }
}

class _ProfileBlobs implements BlobStore {
  _ProfileBlobs(this.root, this.id);
  final BlobStore root;
  final String id;
  String _path(String name) {
    if (name.startsWith('/') ||
        name.split('/').any((p) => p == '..' || p == '.')) {
      throw ArgumentError('invalid profile blob path');
    }
    return 'profiles/$id/$name';
  }

  @override
  Future<Uint8List?> read(String name) => root.read(_path(name));
  @override
  Future<void> write(String name, List<int> bytes) =>
      root.write(_path(name), bytes);
  @override
  Future<void> delete(String name) => root.delete(_path(name));
}
