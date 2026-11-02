/// ADR-062: application-owned TCP routing, below target TLS and script policy.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../credential/blob_store.dart';

class AppTunnelException implements Exception {
  const AppTunnelException(this.code);
  final String code;
  @override
  String toString() => 'AppTunnelException($code)';
}

/// Registered by the application build, never installed by a school script.
abstract interface class AppTunnelProvider {
  String get id;
  String get name;
  bool get isAvailable;
  Future<AppTunnelConnection> open({required String schoolId});
}

abstract interface class AppTunnelConnection {
  Future<List<InternetAddress>> resolve(String host);
  Future<ConnectionTask<Socket>> connect(
    String host,
    InternetAddress address,
    int port,
  );
  void close();
}

/// One immutable routing choice for one invocation; initialization is lazy.
class AppTunnelRoute {
  AppTunnelRoute(this.provider, this.schoolId);
  final AppTunnelProvider provider;
  final String schoolId;
  Future<AppTunnelConnection>? _opening;
  AppTunnelConnection? _connection;
  final _pending = <ConnectionTask<Socket>>{};
  final _sockets = <Socket>{};
  bool _closed = false;

  void _check() {
    if (_closed) throw const AppTunnelException('app_tunnel_cancelled');
  }

  Future<AppTunnelConnection> _open() async {
    _check();
    if (!provider.isAvailable) {
      throw const AppTunnelException('app_tunnel_unavailable');
    }
    final connection = await (_opening ??= provider.open(schoolId: schoolId));
    if (_closed) {
      // Only the initialization continuation owns late-handle disposal.
      if (!identical(_connection, connection)) {
        _connection = connection;
        connection.close();
      }
      _check();
    }
    _connection = connection;
    return connection;
  }

  Future<List<InternetAddress>> resolve(String host) async {
    try {
      final connection = await _open();
      final addresses = await connection.resolve(host);
      _check();
      if (addresses.isEmpty || addresses.length > 64) {
        throw const AppTunnelException('app_tunnel_dns_failed');
      }
      return addresses;
    } on AppTunnelException {
      rethrow;
    } catch (_) {
      _check();
      throw const AppTunnelException('app_tunnel_dns_failed');
    }
  }

  Future<ConnectionTask<Socket>> connect(
    String host,
    InternetAddress address,
    int port,
  ) async {
    try {
      final connection = await _open();
      final task = await connection.connect(host, address, port);
      if (_closed) {
        task.cancel();
        // A native dial can complete after cancellation and still own a socket.
        task.socket.then((socket) => socket.destroy(), onError: (Object _) {});
        _check();
      }
      _pending.add(task);
      var cancelled = false;
      Socket? accepted;
      final future = task.socket.then(
        (socket) {
          _pending.remove(task);
          if (_closed || cancelled) {
            socket.destroy();
            throw const AppTunnelException('app_tunnel_cancelled');
          }
          accepted = socket;
          _sockets.add(socket);
          socket.done.then<void>(
            (_) => _sockets.remove(socket),
            onError: (Object _) => _sockets.remove(socket),
          );
          return socket;
        },
        onError: (Object _) {
          _pending.remove(task);
          _check();
          throw const AppTunnelException('app_tunnel_connection_failed');
        },
      );
      future.then<void>((_) {}, onError: (Object _) {});
      return ConnectionTask.fromSocket(future, () {
        cancelled = true;
        accepted?.destroy();
        task.cancel();
      });
    } on AppTunnelException {
      rethrow;
    } catch (_) {
      _check();
      throw const AppTunnelException('app_tunnel_connection_failed');
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final task in _pending.toList()) {
      task.cancel();
    }
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    _pending.clear();
    _sockets.clear();
    _connection?.close();
  }
}

/// Separate file per school: a broken choice cannot silently reset another.
/// BlobStore is already scoped to the current Profile by its owner.
class AppTunnelRouting {
  AppTunnelRouting({
    required this.blobs,
    required List<AppTunnelProvider> providers,
  }) : providers = List.unmodifiable(providers) {
    final ids = <String>{};
    for (final provider in providers) {
      if (!_id.hasMatch(provider.id) || !ids.add(provider.id)) {
        throw ArgumentError('invalid_app_tunnel_provider');
      }
    }
  }
  static final _id = RegExp(r'^[a-z][a-z0-9-]{0,63}$');
  final Future<BlobStore?> Function() blobs;
  final List<AppTunnelProvider> providers;
  final _choices = <String, Future<String?>>{};
  String _key(String school) =>
      'app-tunnel-${sha256.convert(utf8.encode(school))}.json';

  Future<String?> choice(String schoolId) =>
      _choices[schoolId] ??= _read(schoolId);

  Future<String?> _read(String school) async {
    try {
      final raw = await (await blobs())?.read(_key(school));
      if (raw == null) return null;
      if (raw.length > 2048) throw const FormatException();
      final value = jsonDecode(utf8.decode(raw));
      if (value is! Map ||
          value['version'] != 1 ||
          value['schoolId'] != school ||
          !value.containsKey('providerId')) {
        throw const FormatException();
      }
      final id = value['providerId'];
      if (id != null && (id is! String || !_id.hasMatch(id))) {
        throw const FormatException();
      }
      return id as String?;
    } catch (_) {
      throw const AppTunnelException('app_tunnel_selection_invalid');
    }
  }

  Future<void> save(String schoolId, String? id) async {
    if (id != null && !providers.any((provider) => provider.id == id)) {
      throw const AppTunnelException('app_tunnel_unknown_provider');
    }
    final storage = await blobs();
    // In-memory profiles can make an explicitly temporary choice.
    await storage?.write(
      _key(schoolId),
      utf8.encode(
        jsonEncode({'version': 1, 'schoolId': schoolId, 'providerId': id}),
      ),
    );
    _choices[schoolId] = Future.value(id);
  }

  Future<AppTunnelRoute?> route(String schoolId) async {
    final id = await choice(schoolId);
    if (id == null) return null;
    final provider = providers.where((p) => p.id == id).firstOrNull;
    if (provider == null) {
      throw const AppTunnelException('app_tunnel_unavailable');
    }
    return AppTunnelRoute(provider, schoolId);
  }
}
