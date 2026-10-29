/// 🔒 Trusted async JavaScript in a background isolate (ADR-034 §3–§6).
/// Raw credentials and response headers are intentional in this path. This is
/// independent of the legacy Broker/Masker execution contract.
library;

import 'dart:async';
import 'dart:convert';

import 'package:elecon_contract/output_validator_registry.dart';
import 'package:flutter_qjs_next/flutter_qjs.dart';

import 'credentials.dart';
import 'manifest.dart';

class ScriptRunException implements Exception {
  const ScriptRunException(this.code);
  final String code;
  @override
  String toString() => 'ScriptRunException($code)';
}

class TrustedScriptRuntime {
  const TrustedScriptRuntime();

  Future<Object?> run({
    required ScriptPackage package,
    required String capability,
    Map<String, dynamic> params = const {},
    required ScriptCredentials credentials,
    required Future<Map<String, Object?>> Function(String, Map<String, dynamic>)
    fetch,
    Future<Object?> Function(String, Map<String, Object?>)? browserCall,
    bool Function()? isActive,
    String? htmlStdlib,
    void Function(String level, String message)? onLog,
    Duration wallTimeout = const Duration(seconds: 35),
    int cpuTimeoutMs = 5000,
    int memoryBytes = 64 * 1024 * 1024,
    int maxOutputBytes = 4 * 1024 * 1024,
    int maxHostCalls = 256,
    int maxRequests = 20,
  }) async {
    if (wallTimeout <= Duration.zero ||
        wallTimeout > const Duration(minutes: 2) ||
        cpuTimeoutMs < 1 ||
        cpuTimeoutMs > 15000 ||
        memoryBytes < 1024 * 1024 ||
        memoryBytes > 128 * 1024 * 1024 ||
        maxOutputBytes < 1 ||
        maxOutputBytes > 4 * 1024 * 1024 ||
        maxHostCalls < 1 ||
        maxHostCalls > 1024 ||
        maxRequests < 1 ||
        maxRequests > 40) {
      throw const ScriptRunException('invalid_limits');
    }
    final decl = package.manifest.capability(capability);
    if (decl == null) throw const ScriptRunException('capability_not_declared');
    if (credentials.schoolId != package.manifest.schoolId) {
      throw const ScriptRunException('identity_mismatch');
    }
    final validator = outputValidatorFor(decl.schema, decl.schemaVersion);
    if (validator == null) throw const ScriptRunException('schema_unsupported');
    final paramsJson = jsonEncode(params);
    if (utf8.encode(paramsJson).length > 1024 * 1024) {
      throw const ScriptRunException('params_limit');
    }
    var running = true;
    var hostCalls = 0;
    var requests = 0;
    final knownSecrets = credentials.secretValues.toSet();
    var logs = 0;
    var logBytes = 0;
    ScriptRunException? fatal;
    void check({bool count = true}) {
      if (fatal != null) throw fatal!;
      if (!running || !(isActive?.call() ?? true)) {
        throw const ScriptRunException('invocation_cancelled');
      }
      if (count && ++hostCalls > maxHostCalls) {
        fatal = const ScriptRunException('host_call_limit');
        throw fatal!;
      }
    }

    check(count: false);
    final qjs = IsolateQjs(
      timeout: cpuTimeoutMs,
      memoryLimit: memoryBytes,
      moduleHandler: (name) async {
        check(count: false);
        if (name == 'adapter') return package.source;
        if (name == 'elecon:html' && htmlStdlib != null) return htmlStdlib;
        throw const ScriptRunException('module_not_available');
      },
      // Source-controlled rejection text can contain secrets; errors are codes.
      hostPromiseRejectionHandler: (_) {},
    );
    qjs.setHostFunctions({
      '__script_fetch': (dynamic url, dynamic init) async {
        check();
        if (++requests > maxRequests) {
          fatal = const ScriptRunException('request_limit');
          throw fatal!;
        }
        if (url is! String || init is! Map) {
          throw const ScriptRunException('invalid_fetch');
        }
        final uri = Uri.tryParse(url);
        if (uri == null || !package.manifest.network.allowsUrl(uri)) {
          throw const ScriptRunException('network_denied');
        }
        try {
          final response = await fetch(url, Map<String, dynamic>.from(init));
          check(count: false);
          // The pinned isolate bridge maps a Dart null field to JS undefined.
          // Preserve explicit decoding failure with a separate boolean marker.
          return <String, Object?>{
            ...response,
            'textAvailable':
                !response.containsKey('body') || response['body'] is String,
          };
        } on ScriptRunException {
          rethrow;
        } catch (_) {
          throw const ScriptRunException('fetch_failed');
        }
      },
      '__script_credentials':
          (dynamic method, dynamic key, dynamic value, dynamic options) {
            check();
            try {
              switch (method) {
                case 'get':
                  if (key is! String) {
                    throw const ScriptRunException('invalid_credential_key');
                  }
                  final record = credentials.get(key);
                  if (record != null &&
                      (record['value'] as String).isNotEmpty) {
                    knownSecrets.add(record['value'] as String);
                  }
                  return jsonEncode(record);
                case 'list':
                  final records = credentials.list();
                  knownSecrets.addAll(
                    records
                        .map((r) => r['value'] as String)
                        .where((v) => v.isNotEmpty),
                  );
                  return jsonEncode(records);
                case 'delete':
                  if (key is! String) {
                    throw const ScriptRunException('invalid_credential_key');
                  }
                  credentials.delete(key);
                  return 'null';
                case 'set':
                  if (key is! String || value is! String || options is! Map) {
                    throw const ScriptRunException('invalid_credential_value');
                  }
                  final type = options['type'];
                  final expiresAt = options['expiresAt'];
                  final scope = options['scope'];
                  if ((type != null && type is! String) ||
                      (expiresAt != null && expiresAt is! int) ||
                      (scope != null &&
                          (scope is! List ||
                              scope.any((item) => item is! String)))) {
                    throw const ScriptRunException(
                      'invalid_credential_options',
                    );
                  }
                  if (value.isNotEmpty) knownSecrets.add(value);
                  credentials.set(
                    key,
                    value,
                    type: type as String? ?? 'token',
                    expiresAt: expiresAt as int?,
                    scope: scope == null
                        ? const []
                        : List<String>.from(scope as List),
                  );
                  return 'null';
                default:
                  throw const ScriptRunException(
                    'invalid_credential_operation',
                  );
              }
            } on ScriptCredentialException catch (e) {
              throw ScriptRunException(e.code);
            }
          },
      '__script_browser': (dynamic method, dynamic args) async {
        check();
        if (!package.manifest.browser || browserCall == null) {
          throw const ScriptRunException('browser_unavailable');
        }
        if (method is! String || args is! Map) {
          throw const ScriptRunException('invalid_browser_operation');
        }
        try {
          final result = await browserCall(
            method,
            Map<String, Object?>.from(args),
          );
          check(count: false);
          if (method == 'cookies' && result is List) {
            for (final cookie in result) {
              if (cookie is Map &&
                  cookie['value'] is String &&
                  (cookie['value'] as String).isNotEmpty) {
                knownSecrets.add(cookie['value'] as String);
              }
            }
          }
          if (utf8.encode(jsonEncode(result)).length > maxOutputBytes) {
            throw const ScriptRunException('browser_result_limit');
          }
          return jsonEncode(result);
        } on ScriptRunException {
          rethrow;
        } catch (_) {
          throw const ScriptRunException('browser_failed');
        }
      },
      '__script_log': (dynamic level, dynamic message) {
        check();
        if (++logs > 100) return null;
        var clean = message is String ? message : '';
        if (clean.length > 4096) clean = clean.substring(0, 4096);
        for (final secret in knownSecrets) {
          clean = clean.replaceAll(secret, '[credential]');
        }
        clean = clean.replaceAll(RegExp(r'https?://[^\s]+'), '[url]');
        logBytes += utf8.encode(clean).length;
        if (logBytes <= 64 * 1024) {
          onLog?.call(
            const {'debug', 'info', 'warn', 'error'}.contains(level)
                ? level as String
                : 'info',
            clean,
          );
        }
        return null;
      },
    });

    final cancelled = Completer<Object?>();
    final timer = Timer.periodic(const Duration(milliseconds: 25), (_) {
      if (!(isActive?.call() ?? true) && !cancelled.isCompleted) {
        cancelled.completeError(
          const ScriptRunException('invocation_cancelled'),
        );
      }
    });
    try {
      Future<Object?> execute() async {
        // Install sanitized console before importing source: module top-level
        // console calls otherwise use the QuickJS library's process logger.
        await qjs.evaluate(r'''(() => {
          const output = {};
          for (const level of ['log','info','warn','error','debug']) {
            output[level] = (...args) => globalThis.__script_log(
              level === 'log' ? 'info' : level,
              args.map(value => String(value)).join(' '));
          }
          Object.defineProperty(globalThis, 'console', {
            value: Object.freeze(output), writable: false, configurable: false
          });
        })()''');
        await qjs.evaluate(
          "import * as adapter from 'adapter'; globalThis.__scriptCaps = adapter.capabilities;",
          name: '<script-load>',
          evalFlags: JSEvalFlag.MODULE,
        );
        check(count: false);
        return qjs.evaluate(
          _bootstrap(
            capability: capability,
            paramsJson: paramsJson,
            browser: package.manifest.browser,
            maxOutputBytes: maxOutputBytes,
          ),
        );
      }

      final raw = await Future.any([execute(), cancelled.future]).timeout(
        wallTimeout,
        onTimeout: () => throw const ScriptRunException('wall_timeout'),
      );
      check(count: false);
      if (raw is! String || utf8.encode(raw).length > maxOutputBytes) {
        throw const ScriptRunException('output_limit');
      }
      final outcome = jsonDecode(raw);
      if (outcome is! Map || outcome['ok'] != true) {
        throw ScriptRunException(
          outcome is Map && outcome['code'] is String
              ? outcome['code'] as String
              : 'adapter_failed',
        );
      }
      final output = outcome['data'];
      if (!validator(output)) {
        throw const ScriptRunException('schema_validation_failed');
      }
      return output;
    } on ScriptRunException {
      rethrow;
    } catch (_) {
      // Neither JS exceptions nor engine text are trusted diagnostic content.
      throw const ScriptRunException('execution_failed');
    } finally {
      running = false;
      timer.cancel();
      // The engine interrupt bounds synchronous work before the close message.
      await qjs.close()?.timeout(
        Duration(milliseconds: cpuTimeoutMs + 1000),
        onTimeout: () => null,
      );
    }
  }
}

String _bootstrap({
  required String capability,
  required String paramsJson,
  required bool browser,
  required int maxOutputBytes,
}) =>
    '''
(async () => {
  const caps = globalThis.__scriptCaps;
  if (!caps || typeof caps !== 'object' || typeof caps[${jsonEncode(capability)}] !== 'function') {
    return JSON.stringify({ok:false,code:'capability_missing'});
  }
  const hostCredentials = (method,key,value,options) =>
    Promise.resolve(globalThis.__script_credentials(method,key,value,options || {})).then(JSON.parse);
  const ctx = {
    now: () => Date.now(),
    log: (level,message) => globalThis.__script_log(level,String(message)),
    credentials: Object.freeze({
      get: key => hostCredentials('get',key,null,{}),
      list: () => hostCredentials('list',null,null,{}),
      set: (key,value,options) => hostCredentials('set',key,value,options),
      delete: key => hostCredentials('delete',key,null,{}),
    }),
    fetch: async (url,init) => {
      const r = await globalThis.__script_fetch(String(url),init || {});
      const raw = r.headers || {};
      const find = name => {
        const key = Object.keys(raw).find(k => k.toLowerCase() === String(name).toLowerCase());
        return key === undefined ? [] : (Array.isArray(raw[key]) ? raw[key].map(String) : [String(raw[key])]);
      };
      const headers = Object.freeze({
        get: name => { const v = find(name); return v.length ? v.join(', ') : null; },
        getSetCookie: () => find('set-cookie'),
        raw: () => JSON.parse(JSON.stringify(raw)),
      });
      const text = () => {
        if (r.textAvailable === false) throw new Error('unsupported_encoding');
        return r.body === undefined ? '' : r.body;
      };
      return Object.freeze({status:r.status,ok:r.status>=200 && r.status<300,url:r.url,headers,
        text:async()=>text(),json:async()=>JSON.parse(text()),
        bytes:async()=>new Uint8Array(r.bodyBytes || []),
        arrayBuffer:async()=>(new Uint8Array(r.bodyBytes || [])).buffer});
    },
  };
  if ($browser) {
    const call = async (method,args) => JSON.parse(await globalThis.__script_browser(method,args));
    ctx.browser = Object.freeze({
      open: url => call('open',{url:String(url)}),
      evaluate: (source,...args) => call('evaluate',{
        source:typeof source === 'function' ? '(' + String(source) + ').apply(null,' + JSON.stringify(args) + ')' : String(source)
      }),
      text: selector => call('text',{selector:String(selector)}),
      exists: selector => call('exists',{selector:String(selector)}),
      queryAll: (selector,limit=100) => call('queryAll',{selector:String(selector),limit}),
      waitFor: (selector,timeout=10000) => call('waitFor',{selector:String(selector),timeout}),
      cookies: url => call('cookies',url === undefined ? {} : {url:String(url)}),
    });
  }
  // Build JSON ourselves: JSON.stringify silently drops unsupported values and
  // invokes toJSON. Strict output never repairs missing/NaN/class values.
  let nodes = 0;
  const seen = new Set();
  const max = $maxOutputBytes;
  const encode = (value,depth) => {
    if (++nodes > 100000 || depth > 64) throw new Error('output_limit');
    let text;
    if (value === null) return 'null';
    if (typeof value === 'string' || typeof value === 'boolean') text = JSON.stringify(value);
    else if (typeof value === 'number' && Number.isFinite(value)) text = String(value);
    else if (typeof value === 'object') {
      if (seen.has(value)) throw new Error('non_json_output');
      seen.add(value);
      if (Array.isArray(value)) {
        const parts = [];
        for(let i=0;i<value.length;i++) parts.push(encode(value[i],depth+1));
        text = '['+parts.join(',')+']';
      } else {
        const proto = Object.getPrototypeOf(value);
        if (proto !== Object.prototype && proto !== null) throw new Error('non_json_output');
        if (Object.getOwnPropertySymbols(value).length) throw new Error('non_json_output');
        text = '{'+Object.keys(value).map(key=>JSON.stringify(key)+':'+encode(value[key],depth+1)).join(',')+'}';
      }
      seen.delete(value);
    } else throw new Error('non_json_output');
    if (text.length > max) throw new Error('output_limit');
    return text;
  };
  try {
    const result = await caps[${jsonEncode(capability)}](Object.freeze(ctx),JSON.parse(${jsonEncode(paramsJson)}));
    return '{"ok":true,"data":'+encode(result,0)+'}';
  } catch(e) {
    const code = e && (e.message === 'non_json_output' || e.message === 'output_limit' || e.message === 'unsupported_encoding') ? e.message : 'adapter_failed';
    return JSON.stringify({ok:false,code});
  }
})()
''';
