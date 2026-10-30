/// 🔒 ADR-034 §5: trusted page execution within an exclusive school session.
/// Page results are untrusted data; this bridge grants no native controller.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'network_policy.dart';

class ScriptBrowserException implements Exception {
  const ScriptBrowserException(this.code);
  final String code;
  @override
  String toString() => 'ScriptBrowserException($code)';
}

/// Shared with legacy login/mint: hold the lease through native cleanup.
class ScriptBrowserLease {
  ScriptBrowserLease._();
  static ScriptBrowserLease? _active;
  bool _released = false;
  static bool get busy => _active != null;
  static ScriptBrowserLease? tryAcquire([String owner = 'script']) {
    if (_active != null) return null;
    return _active = ScriptBrowserLease._();
  }

  void release() {
    if (_released) return;
    _released = true;
    if (identical(_active, this)) _active = null;
  }
}

enum ScriptBrowserPhase { waiting, loading, ready, blocked, failed, closed }

class ScriptBrowserState {
  const ScriptBrowserState(this.phase, {this.origin, this.errorCode});
  final ScriptBrowserPhase phase;

  /// Origin only: paths and queries can contain authentication material.
  final String? origin;
  final String? errorCode;
}

/// Platform seam. Implementations must route only this page's completion data
/// into [ScriptBrowserBridge.receiveResult], and must not log source/results.
abstract interface class ScriptBrowserDriver {
  Future<void> initialize();
  Future<void> loadUrl(String url);
  Future<void> evaluate(String source);
  Future<List<Map<String, Object?>>> cookies(Uri url);
  Future<void> setCookies(String url, List<Map<String, Object?>> cookies);
  Future<void> clearFocus();
  Future<void> stopLoading();
  Future<void> close();
}

class ScriptBrowserBridge {
  ScriptBrowserBridge({
    required this.policy,
    bool? available,
    this.loadTimeout = const Duration(seconds: 30),
    this.evaluateTimeout = const Duration(seconds: 30),
    this.maxResultBytes = 1024 * 1024,
  }) : available = available ?? platformSupported;

  static bool get platformSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);
  static const resultHandler = '__eleconScriptResult';
  final ScriptNetworkPolicy policy;
  final bool available;
  final Duration loadTimeout;
  final Duration evaluateTimeout;
  final int maxResultBytes;
  final ValueNotifier<ScriptBrowserState> state = ValueNotifier(
    const ScriptBrowserState(ScriptBrowserPhase.waiting),
  );
  // ADR-039 §1: fixed host presentation, scoped to this browser invocation.
  final ValueNotifier<bool> busy = ValueNotifier(false);
  final _driverReady = Completer<ScriptBrowserDriver>();
  final _random = Random.secure();
  final _closedSignal = Completer<void>();
  final Map<String, Completer<Object?>> _pending = {};
  ScriptBrowserDriver? _driver;
  ScriptBrowserLease? _lease;
  Completer<void>? _loading;
  Uri? _currentUrl;
  bool _closed = false;
  Future<void>? _closing;

  /// Called before constructing a platform view, so native session state is
  /// never touched while another login or script owns the global WebView store.
  void prepare() {
    _checkActive();
    if (!available) {
      throw const ScriptBrowserException('browser_unavailable');
    }
    if (policy.ipAllow != null) {
      throw const ScriptBrowserException('browser_ip_policy_unsupported');
    }
    if (_lease == null) {
      _lease = ScriptBrowserLease.tryAcquire();
      if (_lease == null) {
        throw const ScriptBrowserException('browser_busy');
      }
    }
  }

  void attach(ScriptBrowserDriver driver) {
    prepare();
    if (_driver != null || _driverReady.isCompleted) {
      throw const ScriptBrowserException('browser_already_attached');
    }
    _driver = driver;
    unawaited(_initialize(driver));
  }

  Future<void> _initialize(ScriptBrowserDriver driver) async {
    try {
      await driver.initialize();
      _checkActive();
      if (!_driverReady.isCompleted) _driverReady.complete(driver);
    } catch (_) {
      if (!_driverReady.isCompleted) {
        _driverReady.completeError(
          const ScriptBrowserException('browser_initialization_failed'),
        );
        _driverReady.future.ignore();
      }
      if (!_closed) reportError();
    }
  }

  void _checkActive() {
    if (_closed) throw const ScriptBrowserException('browser_closed');
  }

  Future<ScriptBrowserDriver> _ready() async {
    prepare();
    final ScriptBrowserDriver driver;
    try {
      driver = await _driverReady.future.timeout(loadTimeout);
    } on ScriptBrowserException {
      rethrow;
    } catch (_) {
      throw const ScriptBrowserException('browser_not_ready');
    }
    _checkActive();
    return driver;
  }

  Future<Object?> call(String method, Map<String, Object?> args) async {
    _checkActive();
    switch (method) {
      case 'setBusy':
        final value = args['busy'];
        if (value is! bool) {
          throw const ScriptBrowserException('browser_invalid_argument');
        }
        final driver = await _ready();
        _checkActive();
        busy.value = value;
        if (value) {
          await _whileActive(driver.clearFocus()).timeout(evaluateTimeout);
          _checkActive();
        }
        return null;
      case 'open':
        await open(_string(args, 'url'));
        return null;
      case 'evaluate':
        return evaluate(_string(args, 'source'));
      case 'text':
        return evaluate(
          _expression(
            '(s) => { const e=document.querySelector(s); return e ? e.textContent.trim() : null; }',
            [_string(args, 'selector')],
          ),
        );
      case 'exists':
        return evaluate(
          _expression('(s) => document.querySelector(s) !== null', [
            _string(args, 'selector'),
          ]),
        );
      case 'queryAll':
        final limit = _integer(args, 'limit', 100, 1, 1000);
        return evaluate(
          _expression(
            '(s,n) => Array.from(document.querySelectorAll(s)).slice(0,n).map(e => ({tag:e.tagName.toLowerCase(),text:(e.textContent || "").trim().slice(0,4096),href:e.href || null}))',
            [_string(args, 'selector'), limit],
          ),
        );
      case 'waitFor':
        final timeoutMs = _integer(args, 'timeout', 10000, 1, 30000);
        return evaluate(
          _expression(
            '(s,t) => new Promise((resolve,reject) => { if(document.querySelector(s)) return resolve(true); const o=new MutationObserver(() => { if(!document.querySelector(s)) return; o.disconnect(); clearTimeout(timer); resolve(true); }); o.observe(document.documentElement,{childList:true,subtree:true}); const timer=setTimeout(() => { o.disconnect(); reject(new Error("wait_timeout")); },t); })',
            [_string(args, 'selector'), timeoutMs],
          ),
        );
      case 'setCookies':
        final target = _checkedUrl(_string(args, 'url'));
        final cookies = _validatedCookies(target, args['cookies']);
        final driver = await _ready();
        try {
          await _whileActive(
            driver.setCookies(target.toString(), cookies),
          ).timeout(evaluateTimeout);
          _checkActive();
        } on ScriptBrowserException {
          rethrow;
        } catch (_) {
          throw const ScriptBrowserException('browser_cookie_write_failed');
        }
        return null;
      case 'cookies':
        final rawUrl = args['url'];
        if (rawUrl != null && rawUrl is! String) {
          throw const ScriptBrowserException('browser_invalid_argument');
        }
        final target = rawUrl == null
            ? _currentUrl
            : _checkedUrl(rawUrl as String);
        if (target == null) {
          throw const ScriptBrowserException('browser_not_loaded');
        }
        policy.checkUrl(target);
        final driver = await _ready();
        final cookies = await _whileActive(
          driver.cookies(target),
        ).timeout(evaluateTimeout);
        _checkActive();
        _checkResultSize(cookies);
        return cookies;
      default:
        throw const ScriptBrowserException('browser_unknown_method');
    }
  }

  List<Map<String, Object?>> _validatedCookies(Uri target, Object? raw) {
    if (raw is! List || raw.length > 100) {
      throw const ScriptBrowserException('browser_cookie_limit');
    }
    try {
      if (utf8.encode(jsonEncode(raw)).length > 65536) {
        throw const ScriptBrowserException('browser_cookie_limit');
      }
    } on ScriptBrowserException {
      rethrow;
    } catch (_) {
      throw const ScriptBrowserException('browser_invalid_cookie');
    }
    final result = <Map<String, Object?>>[];
    for (final rawCookie in raw) {
      if (rawCookie is! Map ||
          rawCookie.keys.any(
            (key) => !const {
              'name',
              'value',
              'domain',
              'path',
              'expiresDate',
              'isSecure',
              'isHttpOnly',
              'sameSite',
            }.contains(key),
          )) {
        throw const ScriptBrowserException('browser_invalid_cookie');
      }
      final name = rawCookie['name'];
      final value = rawCookie['value'];
      final domain = rawCookie['domain'];
      final path = rawCookie['path'] ?? '/';
      final expiry = rawCookie['expiresDate'];
      final secure = rawCookie['isSecure'];
      final httpOnly = rawCookie['isHttpOnly'];
      final sameSite = rawCookie['sameSite'];
      if (name is! String ||
          name.length > 256 ||
          !RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$").hasMatch(name) ||
          value is! String ||
          value.codeUnits.any(
            (c) =>
                c < 0x21 ||
                c > 0x7e ||
                const [0x22, 0x2c, 0x3b, 0x5c].contains(c),
          ) ||
          (domain != null && domain is! String) ||
          path is! String ||
          path.length > 2048 ||
          !path.startsWith('/') ||
          path.codeUnits.any((c) => c < 0x20 || c == 0x7f || c == 0x3b) ||
          (expiry != null &&
              (expiry is! num ||
                  !expiry.isFinite ||
                  expiry < 0 ||
                  expiry > 8640000000000000 ||
                  expiry != expiry.round())) ||
          (secure != null && secure is! bool) ||
          (httpOnly != null && httpOnly is! bool) ||
          (sameSite != null &&
              !const {'Lax', 'Strict', 'None'}.contains(sameSite)) ||
          (sameSite == 'None' &&
              !(secure as bool? ?? target.scheme == 'https'))) {
        throw const ScriptBrowserException('browser_invalid_cookie');
      }
      String? normalizedDomain;
      if (domain != null) {
        normalizedDomain = (domain as String).toLowerCase();
        if (normalizedDomain.startsWith('.')) {
          normalizedDomain = normalizedDomain.substring(1);
        }
        final host = target.host.toLowerCase();
        if (normalizedDomain.isEmpty ||
            normalizedDomain.length > 253 ||
            normalizedDomain.endsWith('.') ||
            normalizedDomain.contains('..') ||
            !(host == normalizedDomain ||
                host.endsWith('.$normalizedDomain')) ||
            (InternetAddress.tryParse(host) == null &&
                !normalizedDomain
                    .split('.')
                    .every(
                      (label) => RegExp(
                        r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$',
                      ).hasMatch(label),
                    ))) {
          throw const ScriptBrowserException('browser_invalid_cookie');
        }
      }
      result.add(
        Map<String, Object?>.unmodifiable({
          'name': name,
          'value': value,
          'path': path,
          if (normalizedDomain != null &&
              InternetAddress.tryParse(target.host) == null)
            'domain': normalizedDomain,
          if (expiry != null) 'expiresDate': (expiry as num).toInt(),
          'isSecure': secure ?? target.scheme == 'https',
          'isHttpOnly': httpOnly ?? false,
          'sameSite': ?sameSite,
        }),
      );
    }
    return List.unmodifiable(result);
  }

  Uri _checkedUrl(String value) {
    if (value.length > 8192) {
      throw const ScriptBrowserException('browser_url_too_large');
    }
    final url = Uri.tryParse(value);
    if (url == null || !policy.allowsUrl(url)) {
      busy.value = false;
      throw const ScriptBrowserException('browser_navigation_blocked');
    }
    return url;
  }

  Future<void> open(String url) async {
    final Uri target;
    try {
      target = _checkedUrl(url);
    } on ScriptBrowserException {
      navigationStarted(url);
      rethrow;
    }
    final driver = await _ready();
    _checkActive();
    _failPending('browser_navigation_changed');
    _failLoading('browser_navigation_replaced');
    final loading = _loading = Completer<void>();
    loading.future.ignore();
    _currentUrl = target;
    state.value = ScriptBrowserState(
      ScriptBrowserPhase.loading,
      origin: _origin(target),
    );
    try {
      await _whileActive(
        driver.loadUrl(target.toString()),
      ).timeout(loadTimeout);
      await loading.future.timeout(loadTimeout);
      _checkActive();
    } on ScriptBrowserException {
      rethrow;
    } catch (_) {
      if (!_closed) reportError();
      throw const ScriptBrowserException('browser_load_failed');
    } finally {
      if (identical(_loading, loading)) _loading = null;
    }
  }

  /// Returns false for unapproved navigation; platform must cancel/stop it.
  bool navigationStarted(String? value) {
    if (_closed) return false;
    final url = value == null ? null : Uri.tryParse(value);
    if (url == null || !policy.allowsUrl(url)) {
      busy.value = false;
      _failPending('browser_navigation_blocked');
      _failLoading('browser_navigation_blocked');
      _currentUrl = null;
      state.value = ScriptBrowserState(
        ScriptBrowserPhase.blocked,
        origin: _diagnosticOrigin(url),
        errorCode: 'browser_navigation_blocked',
      );
      return false;
    }
    _failPending('browser_navigation_changed');
    _currentUrl = url;
    state.value = ScriptBrowserState(
      ScriptBrowserPhase.loading,
      origin: _origin(url),
    );
    return true;
  }

  void navigationFinished(String? value) {
    if (_closed || state.value.phase == ScriptBrowserPhase.blocked) return;
    final url = value == null ? null : Uri.tryParse(value);
    if (url == null || !policy.allowsUrl(url)) {
      navigationStarted(value);
      return;
    }
    _currentUrl = url;
    if (busy.value) {
      // ADR-039 §1: a new document can autofocus native input while masked.
      unawaited(
        _driver?.clearFocus().catchError((Object _) {
          if (!_closed) reportError();
        }),
      );
    }
    state.value = ScriptBrowserState(
      ScriptBrowserPhase.ready,
      origin: _origin(url),
    );
    final loading = _loading;
    if (loading != null && !loading.isCompleted) loading.complete();
  }

  bool historyChanged(String? value) {
    if (_closed) return false;
    final url = value == null ? null : Uri.tryParse(value);
    if (url == null || !policy.allowsUrl(url)) return navigationStarted(value);
    _currentUrl = url;
    return true;
  }

  void reportError() {
    if (_closed || state.value.phase == ScriptBrowserPhase.blocked) return;
    busy.value = false;
    _failPending('browser_page_failed');
    _failLoading('browser_page_failed');
    _currentUrl = null;
    state.value = const ScriptBrowserState(
      ScriptBrowserPhase.failed,
      errorCode: 'browser_page_failed',
    );
  }

  Future<Object?> evaluate(String source) async {
    if (utf8.encode(source).length > 256 * 1024) {
      throw const ScriptBrowserException('browser_source_too_large');
    }
    final driver = await _ready();
    if (state.value.phase == ScriptBrowserPhase.blocked) {
      throw const ScriptBrowserException('browser_navigation_blocked');
    }
    if (_currentUrl == null || state.value.phase != ScriptBrowserPhase.ready) {
      throw const ScriptBrowserException('browser_not_loaded');
    }
    policy.checkUrl(_currentUrl!);
    if (_pending.length >= 16) {
      throw const ScriptBrowserException('browser_concurrency_limit');
    }
    final nonce = List.generate(
      16,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final pending = Completer<Object?>();
    pending.future.ignore();
    _pending[nonce] = pending;
    try {
      await _whileActive(
        driver.evaluate(_pageScript(nonce, source)),
      ).timeout(evaluateTimeout);
      return await pending.future.timeout(evaluateTimeout);
    } on ScriptBrowserException {
      rethrow;
    } catch (_) {
      throw const ScriptBrowserException('browser_evaluate_failed');
    } finally {
      _pending.remove(nonce);
    }
  }

  String _pageScript(String nonce, String source) =>
      '''
(() => {
  const nonce = ${jsonEncode(nonce)};
  const reply = (payload) => window.flutter_inappwebview.callHandler(${jsonEncode(resultHandler)}, payload);
  Promise.resolve().then(() => (0,eval)(${jsonEncode(source)})).then(value => {
    let json;
    try { json = JSON.stringify(value === undefined ? null : value); }
    catch (_) { return reply({nonce,ok:false}); }
    if (typeof json !== "string" || json.length > $maxResultBytes) return reply({nonce,ok:false});
    return reply({nonce,ok:true,json});
  }, () => reply({nonce,ok:false}));
  return true;
})()
''';

  /// Called only by the current page's registered completion handler. Nonces
  /// are single-use; navigation/close invalidates all prior completions.
  void receiveResult(Object? value) {
    if (_closed ||
        value is! Map ||
        _currentUrl == null ||
        !policy.allowsUrl(_currentUrl!)) {
      return;
    }
    final nonce = value['nonce'];
    if (nonce is! String) return;
    final pending = _pending.remove(nonce);
    if (pending == null || pending.isCompleted) return;
    if (value['ok'] != true || value['json'] is! String) {
      pending.completeError(
        const ScriptBrowserException('browser_page_script_failed'),
      );
      return;
    }
    final json = value['json'] as String;
    if (utf8.encode(json).length > maxResultBytes) {
      pending.completeError(
        const ScriptBrowserException('browser_result_too_large'),
      );
      return;
    }
    try {
      pending.complete(jsonDecode(json));
    } catch (_) {
      pending.completeError(
        const ScriptBrowserException('browser_invalid_result'),
      );
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    busy.value = false;
    _closedSignal.complete();
    _failPending('browser_closed');
    _failLoading('browser_closed');
    if (!_driverReady.isCompleted) {
      _driverReady.completeError(
        const ScriptBrowserException('browser_closed'),
      );
      _driverReady.future.ignore();
    }
    _currentUrl = null;
    state.value = const ScriptBrowserState(ScriptBrowserPhase.closed);
    try {
      await _driver?.close();
    } finally {
      _lease?.release();
      _lease = null;
      _driver = null;
    }
  }

  Future<T> _whileActive<T>(Future<T> operation) => Future.any([
    operation,
    _closedSignal.future.then<T>(
      (_) => throw const ScriptBrowserException('browser_closed'),
    ),
  ]);

  void _failPending(String code) {
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(ScriptBrowserException(code));
      }
    }
    _pending.clear();
  }

  void _failLoading(String code) {
    final loading = _loading;
    _loading = null;
    if (loading != null && !loading.isCompleted) {
      loading.completeError(ScriptBrowserException(code));
    }
  }

  void _checkResultSize(Object value) {
    if (utf8.encode(jsonEncode(value)).length > maxResultBytes) {
      throw const ScriptBrowserException('browser_result_too_large');
    }
  }

  static String _string(Map<String, Object?> args, String key) {
    final value = args[key];
    if (value is! String || value.length > 256 * 1024) {
      throw const ScriptBrowserException('browser_invalid_argument');
    }
    return value;
  }

  static int _integer(
    Map<String, Object?> args,
    String key,
    int fallback,
    int min,
    int max,
  ) {
    final value = args[key] ?? fallback;
    if (value is! int || value < min || value > max) {
      throw const ScriptBrowserException('browser_invalid_argument');
    }
    return value;
  }

  static String _expression(String function, List<Object?> args) =>
      '($function).apply(null, ${jsonEncode(args)})';
  // ADR-034 §6: diagnostics discard userinfo, path, query and fragment even
  // for rejected URLs. Validate the remaining origin before exposing it to UI.
  static String? _diagnosticOrigin(Uri? url) {
    if (url == null || !const {'http', 'https'}.contains(url.scheme)) {
      return null;
    }
    try {
      final origin = ScriptNetworkPolicy.canonicalOrigin(url).origin;
      ScriptNetworkPolicy.fromJson({
        'origins': [origin],
      });
      return origin;
    } catch (_) {
      return null;
    }
  }

  static String _origin(Uri url) => url.origin;
}
