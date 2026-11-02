/// ADR-062: bounded JSON control calls to the bundled Hermes library.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:ffi/ffi.dart';

import '../app_tunnel.dart';

typedef _NativeCall = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _DartCall = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _NativeFree = Void Function(Pointer<Utf8>);
typedef _DartFree = void Function(Pointer<Utf8>);

const _maxControlBytes = 1024 * 1024;
const _nativeErrors = {
  'hermes_invalid_request',
  'hermes_invalid_configuration',
  'hermes_authentication_required',
  'hermes_connection_failed',
  'hermes_dns_failed',
  'hermes_not_authorized',
  'hermes_cancelled',
  'hermes_closed',
  'hermes_internal_error',
};

String _libraryName() => Platform.isAndroid || Platform.isLinux
    ? 'libelecon_hermes.so'
    : Platform.isMacOS
    ? 'libelecon_hermes.dylib'
    : throw const AppTunnelException('app_tunnel_unavailable');

class HermesNativeBinding {
  /// [libraryPath] is a host/test seam, never a script or UI setting.
  HermesNativeBinding({String? libraryPath}) : _path = libraryPath;
  final String? _path;
  bool? _availability;

  bool get isAvailable => _availability ??= _probe();

  bool _probe() {
    try {
      final path = _path ?? _libraryName();
      final library = DynamicLibrary.open(path);
      library.lookup<NativeFunction<_NativeCall>>('elecon_hermes_call');
      library.lookup<NativeFunction<_NativeFree>>('elecon_hermes_free');
      // The version operation has no I/O or credentials. Every operation that
      // may connect, resolve or authenticate still runs in a worker isolate.
      return _execute(path, const {'op': 'version'})['version'] == 1;
    } catch (_) {
      return false;
    }
  }

  HermesNativeRequest request(Map<String, Object?> values) {
    final random = Random.secure();
    final id = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final path = _path ?? _libraryName();
    final encoded = jsonEncode({...values, 'requestId': id});
    if (utf8.encode(encoded).length > _maxControlBytes) {
      throw const AppTunnelException('hermes_invalid_configuration');
    }
    final result = Isolate.run(() => _execute(path, encoded));
    result.then<void>((_) {}, onError: (Object _) {});
    return HermesNativeRequest._(
      result,
      () =>
          Isolate.run(() => _execute(path, {'op': 'cancel', 'requestId': id})),
    );
  }
}

class HermesNativeRequest {
  HermesNativeRequest._(this.result, this._cancel);
  final Future<Map<String, dynamic>> result;
  final Future<Map<String, dynamic>> Function() _cancel;
  bool _cancelled = false;
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cancel().then<void>((_) {}, onError: (Object _) {});
  }
}

Map<String, dynamic> _execute(String path, Object request) {
  Pointer<Utf8>? input;
  Pointer<Utf8>? output;
  _DartFree? release;
  var inputBytes = 0;
  try {
    final library = DynamicLibrary.open(path);
    final call = library.lookupFunction<_NativeCall, _DartCall>(
      'elecon_hermes_call',
    );
    release = library.lookupFunction<_NativeFree, _DartFree>(
      'elecon_hermes_free',
    );
    final encoded = request is String ? request : jsonEncode(request);
    inputBytes = utf8.encode(encoded).length;
    input = encoded.toNativeUtf8();
    output = call(input);
    if (output == nullptr) throw const FormatException();
    final bytes = output.cast<Uint8>();
    var length = 0;
    while (length <= _maxControlBytes && bytes[length] != 0) {
      length++;
    }
    if (length > _maxControlBytes) throw const FormatException();
    final value = jsonDecode(utf8.decode(bytes.asTypedList(length)));
    if (value is! Map<String, dynamic> || value['ok'] is! bool) {
      throw const FormatException();
    }
    if (value['ok'] != true) {
      throw AppTunnelException(
        _nativeErrors.contains(value['error'])
            ? value['error'] as String
            : 'hermes_internal_error',
      );
    }
    return value;
  } on AppTunnelException {
    rethrow;
  } catch (_) {
    throw const AppTunnelException('app_tunnel_unavailable');
  } finally {
    if (input != null) {
      input.cast<Uint8>().asTypedList(inputBytes).fillRange(0, inputBytes, 0);
      calloc.free(input);
    }
    if (output != null && output != nullptr) release?.call(output);
  }
}
