/// ADR-052: foreground, binary-only WebSocket with bounds before allocation.
/// Authentication and application protocols remain in the school script.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'http_transport.dart' show ScriptAddressResolver;
import 'network_policy.dart';

class ScriptWebSocketTransport {
  ScriptWebSocketTransport({
    required this.policy,
    ScriptAddressResolver? resolver,
    this.securityContext,
  }) : _resolver = resolver ?? InternetAddress.lookup;

  /// Only the separately declared wss origins, represented as https for the
  /// shared canonical-origin/IP policy. It does not include HTTP permissions.
  final ScriptNetworkPolicy policy;
  final SecurityContext? securityContext;
  final ScriptAddressResolver _resolver;
  static const maxMessageBytes = 65536;
  static const maxTotalBytes = 1024 * 1024;
  final _random = Random.secure();
  final _queue = Queue<List<int>>();
  final _buffer = <int>[];
  final _fragment = <int>[];
  HttpClient? _client;
  Socket? _socket;
  Socket? _connectingSocket;
  ConnectionTask<Socket>? _connection;
  Timer? _lifetime;
  Completer<List<int>?>? _receiver;
  var _opened = false;
  var _closed = false;
  var _fragmented = false;
  var _receivedBytes = 0;
  var _sentBytes = 0;
  var _receivedFrames = 0;
  var _sentFrames = 0;
  String _failure = 'websocket_closed';

  Future<Object?> call(String method, Map<String, dynamic> args) async {
    try {
      switch (method) {
        case 'open':
          if (args.keys.toSet().difference({'url'}).isNotEmpty ||
              args['url'] is! String) {
            throw const ScriptNetworkException('websocket_invalid_request');
          }
          await _open(args['url'] as String);
          return null;
        case 'send':
          final bytes = args['bytes'];
          if (args.length != 1 ||
              bytes is! List ||
              bytes.length > maxMessageBytes ||
              bytes.any((b) => b is! int || b < 0 || b > 255)) {
            throw const ScriptNetworkException('websocket_invalid_request');
          }
          _send(2, bytes.cast<int>());
          return null;
        case 'receive':
          final timeout = args['timeoutMs'];
          if (args.length != 1 ||
              timeout is! int ||
              timeout < 1 ||
              timeout > 5000) {
            throw const ScriptNetworkException('websocket_invalid_request');
          }
          return await _receive(timeout);
        case 'close':
          if (args.isNotEmpty) {
            throw const ScriptNetworkException('websocket_invalid_request');
          }
          close();
          return null;
        default:
          throw const ScriptNetworkException('websocket_invalid_request');
      }
    } on ScriptNetworkException {
      rethrow;
    } catch (_) {
      _fail('websocket_failed');
      throw const ScriptNetworkException('websocket_failed');
    }
  }

  Future<void> _open(String url) async {
    if (_opened || _closed) {
      throw const ScriptNetworkException('websocket_open_limit');
    }
    final uri = Uri.tryParse(url);
    if (url.length > 2048 ||
        uri == null ||
        uri.scheme != 'wss' ||
        uri.hasFragment) {
      throw const ScriptNetworkException('websocket_origin_denied');
    }
    final target = uri.replace(scheme: 'https');
    policy.checkUrl(target);
    _opened = true;
    _lifetime = Timer(
      const Duration(seconds: 30),
      () => _fail('websocket_time_limit'),
    );
    try {
      await _handshake(target).timeout(const Duration(seconds: 10));
    } catch (_) {
      _fail('websocket_handshake_failed');
      throw const ScriptNetworkException('websocket_handshake_failed');
    }
  }

  Future<void> _handshake(Uri uri) async {
    final literal = InternetAddress.tryParse(uri.host);
    final addresses = (literal == null ? await _resolver(uri.host) : [literal])
        .where(policy.allowsAddress)
        .toList();
    _check();
    if (addresses.isEmpty) throw const ScriptNetworkException('ip_not_allowed');
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    _client = client;
    client.connectionFactory = (target, proxyHost, proxyPort) async {
      if (target != uri || proxyHost != null || proxyPort != null) {
        throw const ScriptNetworkException('websocket_origin_denied');
      }
      Future<Socket> connect() async {
        // One pinned address and no automatic application-level retry.
        _check();
        final pending = await Socket.startConnect(addresses.first, uri.port);
        _connection = pending;
        if (_closed) {
          pending.cancel();
          _check();
        }
        var socket = await pending.socket;
        unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));
        _connectingSocket = socket;
        if (_closed) {
          socket.destroy();
          _check();
        }
        socket = await SecureSocket.secure(
          socket,
          host: uri.host,
          context: securityContext,
        );
        unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));
        _connectingSocket = socket;
        if (_closed) {
          socket.destroy();
          _check();
        }
        return socket;
      }

      return ConnectionTask.fromSocket(connect(), () {
        _connection?.cancel();
        _connectingSocket?.destroy();
      });
    };
    final nonce = base64Encode(List.generate(16, (_) => _random.nextInt(256)));
    final request = await client.getUrl(uri);
    _check();
    request.followRedirects = false;
    request.headers.set('connection', 'Upgrade');
    request.headers.set('upgrade', 'websocket');
    request.headers.set('sec-websocket-version', '13');
    request.headers.set('sec-websocket-key', nonce);
    final response = await request.close();
    _check();
    final expected = base64Encode(
      sha1
          .convert(
            ascii.encode(
              '$nonce'
              '258EAFA5-E914-47DA-95CA-C5AB0DC85B11',
            ),
          )
          .bytes,
    );
    if (response.statusCode != 101 ||
        response.headers.value('upgrade')?.toLowerCase() != 'websocket' ||
        !(response.headers.value('connection') ?? '')
            .toLowerCase()
            .split(',')
            .map((s) => s.trim())
            .contains('upgrade') ||
        response.headers.value('sec-websocket-accept') != expected ||
        response.headers.value('sec-websocket-extensions') != null ||
        response.headers.value('sec-websocket-protocol') != null) {
      throw const ScriptNetworkException('websocket_handshake_failed');
    }
    final socket = await response.detachSocket();
    if (_closed) {
      socket.destroy();
      _check();
    }
    _socket = socket;
    unawaited(
      socket.done.then<void>(
        (_) {},
        onError: (Object _) => _fail('websocket_failed'),
      ),
    );
    socket.listen(
      _read,
      onError: (Object _) => _fail('websocket_failed'),
      onDone: () => _fail('websocket_closed'),
      cancelOnError: true,
    );
  }

  void _check() {
    if (_closed) throw ScriptNetworkException(_failure);
  }

  void _read(Uint8List chunk) {
    if (_closed) return;
    _receivedBytes += chunk.length;
    if (_receivedBytes > maxTotalBytes) {
      _fail('websocket_byte_limit');
      return;
    }
    _buffer.addAll(chunk);
    try {
      while (_buffer.length >= 2) {
        final first = _buffer[0];
        final second = _buffer[1];
        final fin = first & 128 != 0;
        final opcode = first & 15;
        if (first & 112 != 0 ||
            second & 128 != 0 ||
            !{0, 2, 8, 9, 10}.contains(opcode)) {
          throw const ScriptNetworkException('websocket_frame_invalid');
        }
        var length = second & 127;
        var header = 2;
        if (length == 126) {
          if (_buffer.length < 4) return;
          length = _buffer[2] * 256 + _buffer[3];
          header = 4;
          if (length < 126) {
            throw const ScriptNetworkException('websocket_frame_invalid');
          }
        } else if (length == 127) {
          if (_buffer.length < 10) return;
          // Reject high bits before reading/allocating the claimed payload.
          if (_buffer.sublist(2, 7).any((b) => b != 0)) {
            throw const ScriptNetworkException('websocket_byte_limit');
          }
          length = _buffer[7] * 65536 + _buffer[8] * 256 + _buffer[9];
          header = 10;
          if (length < 65536) {
            throw const ScriptNetworkException('websocket_frame_invalid');
          }
        }
        if (length > maxMessageBytes ||
            (opcode < 8 && _fragment.length + length > maxMessageBytes)) {
          throw const ScriptNetworkException('websocket_byte_limit');
        }
        if (opcode >= 8 &&
            (!fin || length > 125 || (opcode == 8 && length == 1))) {
          throw const ScriptNetworkException('websocket_frame_invalid');
        }
        if (_buffer.length < header + length) return;
        if (++_receivedFrames > 128) {
          throw const ScriptNetworkException('websocket_frame_limit');
        }
        final data = _buffer.sublist(header, header + length);
        _buffer.removeRange(0, header + length);
        if (opcode == 8) {
          _fail('websocket_closed');
          return;
        }
        if (opcode == 9) {
          _send(10, data);
          continue;
        }
        if (opcode == 10) continue;
        if ((opcode == 0 && !_fragmented) || (opcode == 2 && _fragmented)) {
          throw const ScriptNetworkException('websocket_frame_invalid');
        }
        _fragment.addAll(data);
        _fragmented = !fin;
        if (!fin) continue;
        final message = List<int>.of(_fragment);
        _fragment.clear();
        final receiver = _receiver;
        if (receiver != null) {
          _receiver = null;
          receiver.complete(message);
        } else {
          _queue.add(message);
        }
      }
    } on ScriptNetworkException catch (error) {
      _fail(error.code);
    } catch (_) {
      _fail('websocket_frame_invalid');
    }
  }

  void _send(int opcode, List<int> bytes) {
    _check();
    final socket = _socket;
    if (socket == null) {
      throw const ScriptNetworkException('websocket_not_open');
    }
    if (++_sentFrames > 128 ||
        (_sentBytes += bytes.length + 14) > maxTotalBytes) {
      _fail('websocket_send_limit');
      _check();
    }
    final mask = List.generate(4, (_) => _random.nextInt(256));
    final n = bytes.length;
    final frame = <int>[
      128 | opcode,
      if (n < 126)
        128 | n
      else if (n < 65536) ...[
        254,
        n >> 8,
        n & 255,
      ] else ...[
        255,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
      ],
      ...mask,
      for (var i = 0; i < n; i++) bytes[i] ^ mask[i % 4],
    ];
    socket.add(frame);
  }

  Future<List<int>?> _receive(int timeoutMs) async {
    _check();
    if (_socket == null) {
      throw const ScriptNetworkException('websocket_not_open');
    }
    if (_receiver != null) {
      throw const ScriptNetworkException('websocket_receive_busy');
    }
    if (_queue.isNotEmpty) return _queue.removeFirst();
    final pending = Completer<List<int>?>();
    _receiver = pending;
    try {
      return await pending.future.timeout(
        Duration(milliseconds: timeoutMs),
        onTimeout: () => null,
      );
    } finally {
      if (identical(_receiver, pending)) _receiver = null;
    }
  }

  void _fail(String code) {
    _failure = code;
    close();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _lifetime?.cancel();
    _connection?.cancel();
    _socket?.destroy();
    _connectingSocket?.destroy();
    _client?.close(force: true);
    _buffer.clear();
    _fragment.clear();
    _queue.clear();
    final receiver = _receiver;
    _receiver = null;
    receiver?.completeError(ScriptNetworkException(_failure));
  }
}
