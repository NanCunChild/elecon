/// ADR-062: a native Hermes TCP bridge; target TLS stays in Dart transports.
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../app_tunnel.dart';
import 'configuration.dart';
import 'native_binding.dart';

class HermesProvider implements AppTunnelProvider {
  HermesProvider({
    required this.configuration,
    HermesNativeBinding? binding,
    Future<Directory> Function()? socketDirectory,
  }) : _binding = binding ?? HermesNativeBinding(),
       _socketDirectory = socketDirectory ?? _privateDirectory;
  final Future<HermesConfiguration?> Function(String schoolId) configuration;
  final HermesNativeBinding _binding;
  final Future<Directory> Function() _socketDirectory;
  @override
  String get id => 'hermes-atrust';
  @override
  String get name => 'Hermes / aTrust';
  @override
  bool get isAvailable => _binding.isAvailable;
  @override
  Future<AppTunnelConnection> open({required String schoolId}) async {
    if (!isAvailable) throw const AppTunnelException('app_tunnel_unavailable');
    final config = await configuration(schoolId);
    if (config == null) {
      throw const AppTunnelException('hermes_authentication_required');
    }
    return _HermesConnection(_binding, config, await _socketDirectory());
  }
}

Future<Directory> _privateDirectory() async {
  final root = await getApplicationSupportDirectory();
  return Directory('${root.path}/ht').create(recursive: true);
}

class _HermesConnection implements AppTunnelConnection {
  _HermesConnection(this.binding, this.configuration, this.directory);
  final HermesNativeBinding binding;
  final HermesConfiguration configuration;
  final Directory directory;
  final _requests = <HermesNativeRequest>{};
  final _tasks = <ConnectionTask<Socket>>{};
  final _sockets = <Socket>{};
  Future<int>? _starting;
  int? _handle;
  bool _closed = false;
  void _check() {
    if (_closed) throw const AppTunnelException('hermes_closed');
  }

  Future<Map<String, dynamic>> _call(Map<String, Object?> values) async {
    _check();
    final request = binding.request(values);
    _requests.add(request);
    try {
      return await request.result;
    } finally {
      _requests.remove(request);
    }
  }

  Future<int> _start() => _starting ??= () async {
    final response = await _call(configuration.nativeStart(directory.path));
    final handle = response['handle'];
    if (handle is! int || handle < 1) {
      throw const AppTunnelException('hermes_internal_error');
    }
    _handle = handle;
    if (_closed) {
      _stop(handle);
      _check();
    }
    return handle;
  }();
  void _stop(int handle) {
    binding
        .request({'op': 'stop', 'handle': handle})
        .result
        .then<void>((_) {}, onError: (Object _) {});
  }

  @override
  Future<List<InternetAddress>> resolve(String host) async {
    final response = await _call({
      'op': 'resolve',
      'handle': await _start(),
      'host': host,
    });
    _check();
    final values = response['addresses'];
    if (values is! List || values.isEmpty || values.length > 64) {
      throw const AppTunnelException('hermes_dns_failed');
    }
    final result = <InternetAddress>[];
    for (final raw in values) {
      final address = raw is String ? InternetAddress.tryParse(raw) : null;
      if (address == null) throw const AppTunnelException('hermes_dns_failed');
      result.add(address);
    }
    return result;
  }

  @override
  Future<ConnectionTask<Socket>> connect(
    String host,
    InternetAddress address,
    int port,
  ) async {
    final handle = await _start();
    _check();
    var cancelled = false;
    ConnectionTask<Socket>? connecting;
    Socket? socket;
    final request = binding.request({
      'op': 'dial',
      'handle': handle,
      'host': host,
      'address': address.address,
      'port': port,
    });
    _requests.add(request);
    Future<Socket> connect() async {
      try {
        final response = await request.result;
        _check();
        if (cancelled) throw const AppTunnelException('hermes_cancelled');
        final path = response['path'];
        if (path is! String ||
            !path.startsWith('${directory.path}/') ||
            path.substring(directory.path.length + 1).contains('/') ||
            path.contains('/../') ||
            path.length > 107) {
          throw const AppTunnelException('hermes_internal_error');
        }
        connecting = await Socket.startConnect(
          InternetAddress(path, type: InternetAddressType.unix),
          0,
        );
        _tasks.add(connecting!);
        if (_closed || cancelled) {
          connecting!.cancel();
          throw const AppTunnelException('hermes_cancelled');
        }
        socket = await connecting!.socket;
        if (_closed || cancelled) {
          socket!.destroy();
          throw const AppTunnelException('hermes_cancelled');
        }
        _sockets.add(socket!);
        socket!.done.then<void>(
          (_) => _sockets.remove(socket),
          onError: (Object _) => _sockets.remove(socket),
        );
        return socket!;
      } finally {
        _requests.remove(request);
        if (connecting != null) _tasks.remove(connecting);
      }
    }

    final future = connect();
    future.then<void>((_) {}, onError: (Object _) {});
    return ConnectionTask.fromSocket(future, () {
      cancelled = true;
      request.cancel();
      connecting?.cancel();
      socket?.destroy();
    });
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final request in _requests.toList()) {
      request.cancel();
    }
    for (final task in _tasks.toList()) {
      task.cancel();
    }
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    if (_handle case final handle?) _stop(handle);
  }
}
