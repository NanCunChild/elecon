/// 🔒 ADR-034 §4: script-owned credentials, bounded HTTP and pinned DNS.
/// This path never enters the V1 Broker/Masker or logs request/response secrets.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'network_policy.dart';

typedef ScriptAddressResolver = Future<List<InternetAddress>> Function(String);

class ScriptHttpTransport {
  ScriptHttpTransport({
    required this.policy,
    ScriptAddressResolver? resolver,
    this.maxRequests = 40,
    this.maxConcurrent = 4,
    this.maxRedirects = 8,
    this.maxRequestBytes = 1024 * 1024,
    this.maxResponseBytes = 8 * 1024 * 1024,
    this.maxTotalResponseBytes = 16 * 1024 * 1024,
    this.requestTimeout = const Duration(seconds: 30),
  }) : _resolver = resolver ?? InternetAddress.lookup;

  final ScriptNetworkPolicy policy;
  final ScriptAddressResolver _resolver;
  final int maxRequests;
  final int maxConcurrent;
  final int maxRedirects;
  final int maxRequestBytes;
  final int maxResponseBytes;
  final int maxTotalResponseBytes;
  final Duration requestTimeout;
  final Set<HttpClient> _clients = {};
  var _closed = false;
  var _requestCount = 0;
  var _concurrent = 0;
  var _responseBytes = 0;

  Future<Map<String, Object?>> fetch(
    String url,
    Map<String, dynamic> init,
  ) async {
    _assertOpen();
    if (_concurrent >= maxConcurrent) {
      throw const ScriptNetworkException('concurrent_request_limit');
    }
    final context = _FetchContext();
    _concurrent++;
    try {
      return await _fetch(url, init, context).timeout(
        requestTimeout,
        onTimeout: () {
          context.close();
          throw const ScriptNetworkException('request_timeout');
        },
      );
    } on ScriptNetworkException {
      rethrow;
    } catch (_) {
      // Platform errors can contain the URL, query, body or header values.
      throw ScriptNetworkException(
        _closed ? 'transport_closed' : 'http_failed',
      );
    } finally {
      context.close();
      _clients.removeAll(context.clients);
      _concurrent--;
    }
  }

  Future<Map<String, Object?>> _fetch(
    String url,
    Map<String, dynamic> init,
    _FetchContext context,
  ) async {
    if (url.length > 16384) {
      throw const ScriptNetworkException('invalid_url');
    }
    final parsed = Uri.tryParse(url);
    if (parsed == null) throw const ScriptNetworkException('invalid_url');
    policy.checkUrl(parsed);
    var uri = parsed.removeFragment();
    var method = init['method'] ?? 'GET';
    if (method is! String ||
        !RegExp(
          r"^[A-Za-z][A-Za-z0-9!#$%&'*+.^_`|~-]{0,31}$",
        ).hasMatch(method)) {
      throw const ScriptNetworkException('invalid_method');
    }
    method = method.toUpperCase();
    final mode = init['redirect'] ?? 'follow';
    if (mode != 'follow' && mode != 'manual' && mode != 'error') {
      throw const ScriptNetworkException('invalid_redirect_mode');
    }
    final rawBody = init['body'];
    if (rawBody is List && rawBody.length > maxRequestBytes) {
      throw const ScriptNetworkException('request_body_limit');
    }
    if (rawBody != null &&
        rawBody is! String &&
        (rawBody is! List ||
            rawBody.any(
              (value) => value is! int || value < 0 || value > 255,
            ))) {
      throw const ScriptNetworkException('invalid_body');
    }
    List<int>? body = rawBody == null
        ? null
        : rawBody is String
        ? utf8.encode(rawBody)
        : List<int>.from(rawBody as List);
    if (body != null && (method == 'GET' || method == 'HEAD')) {
      throw const ScriptNetworkException('body_not_allowed_for_method');
    }
    if (body != null && body.length > maxRequestBytes) {
      throw const ScriptNetworkException('request_body_limit');
    }
    var headers = _headers(init['headers']);
    for (var hop = 0; ; hop++) {
      _assertActive(context);
      policy.checkUrl(uri);
      if (_requestCount >= maxRequests) {
        throw const ScriptNetworkException('request_count_limit');
      }
      // Reserve before asynchronous resolution so concurrent fetches cannot
      // exceed the invocation's cumulative hop budget.
      _requestCount++;
      final literal = InternetAddress.tryParse(uri.host);
      final addresses = literal == null
          ? await _resolver(uri.host)
          : <InternetAddress>[literal];
      _assertActive(context);
      final permitted = addresses.where(policy.allowsAddress).toList();
      if (permitted.isEmpty) {
        throw const ScriptNetworkException('ip_not_allowed');
      }
      // A new client per hop avoids reusing a connection from an earlier DNS
      // snapshot. The connector receives InternetAddress, never a hostname.
      final client = HttpClient()
        ..findProxy = ((_) => 'DIRECT')
        ..connectionTimeout = requestTimeout
        ..autoUncompress = true;
      _clients.add(client);
      context.clients.add(client);
      client.connectionFactory = (target, proxyHost, proxyPort) async {
        if (proxyHost != null || proxyPort != null) {
          throw const ScriptNetworkException('proxy_not_supported');
        }
        return _connect(target, permitted, context);
      };
      try {
        final request = await client.openUrl(method, uri);
        _assertActive(context);
        request.followRedirects = false;
        headers.forEach(request.headers.set);
        if (body != null) request.add(body);
        final response = await request.close();
        _assertActive(context);
        if (response.contentLength > maxResponseBytes ||
            response.contentLength > maxTotalResponseBytes - _responseBytes) {
          throw const ScriptNetworkException('response_body_limit');
        }
        final responseHeaders = <String, List<String>>{};
        var responseHeaderBytes = 0;
        response.headers.forEach((name, values) {
          responseHeaderBytes += utf8.encode(name).length;
          for (final value in values) {
            responseHeaderBytes += utf8.encode(value).length;
          }
          if (responseHeaders.length >= 100 || responseHeaderBytes > 65536) {
            throw const ScriptNetworkException('response_header_limit');
          }
          responseHeaders[name.toLowerCase()] = List<String>.of(values);
        });
        final bytes = <int>[];
        await for (final chunk in response) {
          _assertActive(context);
          if (bytes.length + chunk.length > maxResponseBytes ||
              _responseBytes + chunk.length > maxTotalResponseBytes) {
            throw const ScriptNetworkException('response_body_limit');
          }
          _responseBytes += chunk.length;
          bytes.addAll(chunk);
        }
        final location = responseHeaders['location'];
        final isRedirect = const {
          301,
          302,
          303,
          307,
          308,
        }.contains(response.statusCode);
        if (!isRedirect || location == null || mode == 'manual') {
          return {
            'status': response.statusCode,
            'url': uri.toString(),
            'headers': responseHeaders,
            'bodyBytes': List<int>.unmodifiable(bytes),
            'body': _decodeResponse(bytes, response.headers),
          };
        }
        if (mode == 'error') {
          throw const ScriptNetworkException('redirect_disallowed');
        }
        if (hop >= maxRedirects) {
          throw const ScriptNetworkException('redirect_limit');
        }
        if (location.length != 1 || location.single.length > 16384) {
          throw const ScriptNetworkException('invalid_redirect');
        }
        final Uri target;
        try {
          target = uri.resolve(location.single).removeFragment();
        } on FormatException {
          throw const ScriptNetworkException('invalid_redirect');
        }
        policy.checkUrl(target);
        final crossOrigin =
            ScriptNetworkPolicy.canonicalOrigin(uri).origin !=
            ScriptNetworkPolicy.canonicalOrigin(target).origin;
        if (response.statusCode == 303 && method != 'HEAD' ||
            const {301, 302}.contains(response.statusCode) &&
                method == 'POST') {
          method = 'GET';
          body = null;
          headers.remove('content-type');
          headers.remove('content-encoding');
        }
        if (crossOrigin) {
          if (body != null) {
            throw const ScriptNetworkException('redirect_body_requires_manual');
          }
          // Unknown custom headers may contain tokens too. Only retain a small
          // set of representation preferences across an origin boundary.
          const safe = {
            'accept',
            'accept-language',
            'cache-control',
            'user-agent',
          };
          headers = Map.fromEntries(
            headers.entries.where((entry) => safe.contains(entry.key)),
          );
        }
        uri = target;
      } finally {
        client.close(force: true);
        _clients.remove(client);
      }
    }
  }

  Future<ConnectionTask<Socket>> _connect(
    Uri uri,
    List<InternetAddress> addresses,
    _FetchContext context,
  ) async {
    var cancelled = false;
    ConnectionTask<Socket>? pending;
    Socket? socket;
    Future<Socket> connect() async {
      for (final address in addresses) {
        _assertActive(context);
        if (cancelled) throw const ScriptNetworkException('transport_closed');
        try {
          pending = await Socket.startConnect(address, uri.port);
          if (cancelled || !context.active || _closed) {
            pending!.cancel();
            throw const ScriptNetworkException('transport_closed');
          }
          socket = await pending!.socket;
          _assertActive(context);
          if (uri.scheme == 'https') {
            // With connectionFactory the SDK does not perform direct TLS for
            // us. SecureSocket keeps SNI/certificate checks on the real host.
            socket = await SecureSocket.secure(socket!, host: uri.host);
            _assertActive(context);
          }
          return socket!;
        } on ScriptNetworkException {
          socket?.destroy();
          rethrow;
        } catch (_) {
          socket?.destroy();
          socket = null;
          if (address == addresses.last) {
            throw const ScriptNetworkException('connection_failed');
          }
        }
      }
      throw const ScriptNetworkException('connection_failed');
    }

    return ConnectionTask.fromSocket(connect(), () {
      cancelled = true;
      pending?.cancel();
      socket?.destroy();
    });
  }

  static Map<String, String> _headers(Object? raw) {
    if (raw == null) return <String, String>{};
    if (raw is! Map || raw.length > 100) {
      throw const ScriptNetworkException('invalid_headers');
    }
    final headers = <String, String>{};
    var total = 0;
    for (final entry in raw.entries) {
      if (entry.key is! String || entry.value is! String) {
        throw const ScriptNetworkException('invalid_headers');
      }
      final name = (entry.key as String).toLowerCase();
      final value = entry.value as String;
      if (!RegExp(r"^[a-z0-9!#$%&'*+.^_`|~-]+$").hasMatch(name) ||
          value.contains(RegExp(r'[\r\n\x00]')) ||
          headers.containsKey(name)) {
        throw const ScriptNetworkException('invalid_headers');
      }
      if (const {
            'host',
            'content-length',
            'transfer-encoding',
            'connection',
            'keep-alive',
            'upgrade',
            'te',
            'trailer',
            'expect',
          }.contains(name) ||
          name.startsWith('proxy-')) {
        throw const ScriptNetworkException('reserved_header');
      }
      total += utf8.encode(name).length + utf8.encode(value).length;
      if (total > 65536) {
        throw const ScriptNetworkException('header_size_limit');
      }
      headers[name] = value;
    }
    return headers;
  }

  static String? _decodeResponse(List<int> bytes, HttpHeaders headers) {
    try {
      return _decode(bytes, headers.contentType?.charset);
    } on HttpException {
      return null;
    } on FormatException {
      return null;
    }
  }

  static String? _decode(List<int> bytes, String? charset) {
    final encoding = charset?.toLowerCase();
    if (encoding == 'iso-8859-1' || encoding == 'latin1') {
      return latin1.decode(bytes);
    }
    if (encoding != null &&
        !const {'utf-8', 'utf8', 'us-ascii', 'ascii'}.contains(encoding)) {
      return null;
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      // Preserve binary/legacy-encoded data for the script's own decoder.
      return null;
    }
  }

  void _assertOpen() {
    if (_closed) throw const ScriptNetworkException('transport_closed');
  }

  void _assertActive(_FetchContext context) {
    _assertOpen();
    if (!context.active) {
      throw const ScriptNetworkException('request_cancelled');
    }
  }

  /// Cancels all requests and makes this invocation's transport unusable.
  void close() {
    _closed = true;
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    _clients.clear();
  }
}

class _FetchContext {
  var active = true;
  final Set<HttpClient> clients = {};

  void close() {
    active = false;
    for (final client in clients) {
      client.close(force: true);
    }
  }
}
