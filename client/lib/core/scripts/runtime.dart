/// 🔒 Trusted async JavaScript in a background isolate (ADR-034 §3–§6).
/// Raw credentials and response headers are intentional in this path. This is
/// independent of the legacy Broker/Masker execution contract.
/// ADR-037: SDK 3 adds bounded transient input, redlines #1/#5/#7 unchanged.
/// ADR-039: SDK 4 adds the fixed browser busy status, preserving cancellation.
/// ADR-046: all capabilities share the ordinary request bridge.
library;

import 'dart:async';
import 'dart:convert';

import 'package:elecon_contract/output_validator_registry.dart';
import 'package:flutter_qjs_next/flutter_qjs.dart';

import 'credentials.dart';
import 'browser.dart';
import 'manifest.dart';
import 'input.dart';
import 'scanner.dart';

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
    ScriptInputCall? inputCall,
    ScriptScanCall? scanCall,
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
    if (package.requiresUpdate) {
      throw const ScriptRunException('script_update_required');
    }
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
    if (credentials.schoolId != package.manifest.schoolId ||
        credentials.sdkVersion != package.manifest.sdkVersion ||
        (package.manifest.sdkVersion >= 2 &&
            credentials.scriptId != package.manifest.id)) {
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
    if (capability.startsWith('climate.') && params['deviceId'] is String) {
      knownSecrets.add(params['deviceId'] as String);
    }
    var logs = 0;
    var logBytes = 0;
    var inputRequests = 0;
    var inputPending = false;
    var scans = 0;
    var scanPending = false;
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
      '__script_scan': (dynamic argumentCount) async {
        check();
        if (package.manifest.sdkVersion < 8 ||
            !package.manifest.scanner ||
            scanCall == null) {
          throw const ScriptRunException('scanner_unavailable');
        }
        if (argumentCount != 0) {
          throw const ScriptRunException('scanner_invalid_request');
        }
        if (scanPending || inputPending) {
          throw const ScriptRunException('scanner_busy');
        }
        if (++scans > 3) throw const ScriptRunException('scanner_limit');
        scanPending = true;
        try {
          final raw = await scanCall(
            () => running && (isActive?.call() ?? true),
          );
          check(count: false);
          if (raw is Map &&
              raw['text'] is String &&
              (raw['text'] as String).isNotEmpty) {
            knownSecrets.add(raw['text'] as String);
          }
          return jsonEncode(validateScanResult(raw));
        } on ScriptScannerException catch (error) {
          throw ScriptRunException(error.code);
        } on ScriptRunException {
          rethrow;
        } catch (_) {
          throw const ScriptRunException('scanner_unavailable');
        } finally {
          scanPending = false;
        }
      },
      '__script_input': (dynamic encoded) async {
        check();
        if (package.manifest.sdkVersion < 3) {
          throw const ScriptRunException('input_unavailable');
        }
        if (inputPending || scanPending) {
          throw const ScriptRunException('input_busy');
        }
        if (++inputRequests > 8) {
          fatal = const ScriptRunException('input_limit');
          throw fatal!;
        }
        if (encoded is! String) {
          throw const ScriptRunException('input_invalid_request');
        }
        try {
          final request = ScriptInputRequest.decode(encoded);
          final input = inputCall;
          if (input == null) {
            throw const ScriptRunException('input_unavailable');
          }
          inputPending = true;
          final raw = await input(request);
          check(count: false);
          // ADR-037 §2: all submitted fields, including ordinary identifiers,
          // are secrets before any JS code can log or persist the result.
          if (raw is Map) {
            for (final value in raw.values) {
              if (value is String && value.isNotEmpty) knownSecrets.add(value);
            }
          }
          return jsonEncode(request.validateResult(raw));
        } on ScriptInputException catch (error) {
          throw ScriptRunException(error.code);
        } on ScriptRunException {
          rethrow;
        } catch (_) {
          throw const ScriptRunException('input_unavailable');
        } finally {
          inputPending = false;
        }
      },
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
              if (options is! Map ||
                  options.keys.any(
                    (key) => !const {
                      'namespace',
                      'type',
                      'scope',
                      'expiresAt',
                    }.contains(key),
                  ) ||
                  (options.containsKey('namespace') &&
                      options['namespace'] is! String)) {
                throw const ScriptRunException('invalid_credential_options');
              }
              final namespace = options['namespace'] as String?;
              switch (method) {
                case 'get':
                  if (key is! String) {
                    throw const ScriptRunException('invalid_credential_key');
                  }
                  final record = credentials.get(key, namespace: namespace);
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
                  credentials.delete(key, namespace: namespace);
                  return 'null';
                case 'set':
                  if (key is! String || value is! String) {
                    throw const ScriptRunException('invalid_credential_value');
                  }
                  final type = options['type'];
                  final expiresAt = options['expiresAt'];
                  final scope = options['scope'];
                  if ((options.containsKey('type') && type is! String) ||
                      (expiresAt != null && expiresAt is! int) ||
                      (options.containsKey('scope') &&
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
                    namespace: namespace,
                    type: type as String?,
                    expiresAt: options.containsKey('expiresAt')
                        ? expiresAt
                        : scriptCredentialUnspecified,
                    scope: scope == null
                        ? null
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
        if (method == 'setBusy' && package.manifest.sdkVersion < 4) {
          throw const ScriptRunException('invalid_browser_operation');
        }
        try {
          // Restored cookies are already known secrets even if the platform
          // rejects the write; diagnostics must never echo their values.
          if (method == 'setCookies' && args['cookies'] is List) {
            for (final cookie in args['cookies'] as List) {
              if (cookie is Map &&
                  cookie['value'] is String &&
                  (cookie['value'] as String).isNotEmpty) {
                knownSecrets.add(cookie['value'] as String);
              }
            }
          }
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
        } on ScriptBrowserException catch (error) {
          // ADR-034 §6: forward only known stable codes, never native text/URLs.
          final code = switch (error.code) {
            'browser_navigation_blocked' ||
            'browser_navigation_changed' ||
            'browser_not_loaded' ||
            'browser_closed' => error.code,
            _ => 'browser_failed',
          };
          throw ScriptRunException(code);
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
      if ((!(isActive?.call() ?? true)) && !cancelled.isCompleted) {
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
              String(args.map(value => String(value)).join(' ')));
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
            browserBusy: package.manifest.sdkVersion >= 4,
            input: package.manifest.sdkVersion >= 3,
            scanner:
                package.manifest.sdkVersion >= 8 && package.manifest.scanner,
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
  required bool browserBusy,
  required bool input,
  required bool scanner,
  required int maxOutputBytes,
}) =>
    '''
(async () => {
  const caps = globalThis.__scriptCaps;
  if (!caps || typeof caps !== 'object' || typeof caps[${jsonEncode(capability)}] !== 'function') {
    return JSON.stringify({ok:false,code:'capability_missing'});
  }
  // flutter_qjs_next 1.2.1 _jsToDart omits STRING_ROPE. QuickJS String()
  // linearizes rope strings; preserve every non-string's type for host checks.
  // ADR-034 execution bridge fix, without changing the SDK or output contract.
  const flat = value => typeof value === 'string' ? String(value) : value;
  const flatFields = value => {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return value;
    const prototype = Object.getPrototypeOf(value);
    if (prototype !== Object.prototype && prototype !== null) return value;
    return Object.fromEntries(Object.keys(value).map(key => [key,flat(value[key])]));
  };
  const hostCredentials = (method,key,value,options) => {
    options = flatFields(options || {});
    if (options && Array.isArray(options.scope)) options.scope = options.scope.map(flat);
    return Promise.resolve(globalThis.__script_credentials(method,flat(key),flat(value),options)).then(JSON.parse);
  };
  const ctx = {
    now: () => Date.now(),
    log: (level,message) => globalThis.__script_log(level,String(message)),
    credentials: Object.freeze({
      get: (key,options) => hostCredentials('get',key,null,options),
      list: () => hostCredentials('list',null,null,{}),
      set: (key,value,options) => hostCredentials('set',key,value,options),
      delete: (key,options) => hostCredentials('delete',key,null,options),
    }),
    fetch: async (url,init) => {
      init = flatFields(init || {});
      if (init && init.headers) init.headers = flatFields(init.headers);
      const r = await globalThis.__script_fetch(String(url),init);
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
  if ($input) {
    ctx.ui = {requestInput: async request => {
      try {
        return JSON.parse(await globalThis.__script_input(String(JSON.stringify(request))));
      } catch (error) {
        const codes = ['input_invalid_request','input_invalid_result','input_unavailable',
          'input_busy','input_limit','invocation_cancelled'];
        const code = codes.find(value => String(error).includes('ScriptRunException(' + value + ')'));
        if (!code) throw error;
        const failure = new Error(code);
        failure.code = code;
        throw failure;
      }
    }};
    if ($scanner) ctx.ui.scanQRCode = async (...args) => {
      try { return JSON.parse(await globalThis.__script_scan(args.length)); }
      catch (error) {
        const codes = ['scanner_unavailable','scanner_invalid_request','scanner_invalid_result',
          'scanner_busy','scanner_limit','scanner_permission_denied','invocation_cancelled'];
        const code = codes.find(value => String(error).includes('ScriptRunException(' + value + ')'));
        if (!code) throw error;
        const failure = new Error(code); failure.code = code; throw failure;
      }
    };
    Object.freeze(ctx.ui);
  }
  if ($browser) {
    const call = async (method,args) => {
      try { return JSON.parse(await globalThis.__script_browser(method,flatFields(args))); }
      catch (error) {
        // The native bridge supplies a fixed code, never its rejected URL.
        if (String(error).includes('ScriptRunException(browser_navigation_blocked)')) {
          const failure = new Error('browser_navigation_blocked');
          failure.code = 'network_denied';
          throw failure;
        }
        throw error;
      }
    };
    ctx.browser = Object.freeze({
      ${browserBusy ? "setBusy: busy => call('setBusy',{busy})," : ''}
      open: url => call('open',{url:String(url)}),
      evaluate: (source,...args) => call('evaluate',{
        source:typeof source === 'function' ? '(' + String(source) + ').apply(null,' + JSON.stringify(args) + ')' : String(source)
      }),
      text: selector => call('text',{selector:String(selector)}),
      exists: selector => call('exists',{selector:String(selector)}),
      queryAll: (selector,limit=100) => call('queryAll',{selector:String(selector),limit}),
      waitFor: (selector,timeout=10000) => call('waitFor',{selector:String(selector),timeout}),
      cookies: url => call('cookies',url === undefined ? {} : {url:String(url)}),
      setCookies: async (url,cookies) => { await call('setCookies',{url:String(url),cookies:Array.isArray(cookies) ? cookies.map(flatFields) : cookies}); },
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
    return String('{"ok":true,"data":'+encode(result,0)+'}');
  } catch(e) {
    // Useful diagnostics go through the same bounded secret/URL sanitizer as
    // ctx.log; the result channel continues to expose stable codes only.
    try {
      const message = String(e && e.message || e);
      const stack = String(e && e.stack || '');
      globalThis.__script_log('error',String((message + '\\n' + stack).slice(0,4096)));
    } catch (_) {}
    // ADR-034 §6: only a fixed vocabulary may cross the error result channel.
    // A script can classify a failure without exposing its message or data.
    const safeCodes = new Set(['input_required_card_number','input_required_student_id',
      'authentication_required','authentication_timeout','source_response_invalid','network_denied',
      'input_invalid_request','input_invalid_result','input_unavailable','input_busy','input_limit','input_cancelled']);
    const code = e && (e.message === 'non_json_output' || e.message === 'output_limit' || e.message === 'unsupported_encoding')
      ? e.message : e && safeCodes.has(e.code) ? e.code : 'adapter_failed';
    return JSON.stringify({ok:false,code});
  }
})()
''';
