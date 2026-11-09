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
import 'account_auth.dart';
import 'browser.dart';
import 'manifest.dart';
import 'input.dart';
import 'scanner.dart';
import 'device_input.dart';
import 'host_protocol.dart';
import 'runtime_bootstrap.dart';
import 'query_filters.dart';
import 'execution.dart';

export 'host_protocol.dart' show ScriptRunException;

class TrustedScriptRuntime {
  const TrustedScriptRuntime();

  Future<Object?> run({
    required ScriptPackage package,
    required String capability,
    String locale = 'zh',
    Map<String, dynamic> params = const {},
    required ScriptCredentials credentials,
    required Future<Map<String, Object?>> Function(String, Map<String, dynamic>)
    fetch,
    Future<Object?> Function(String, Map<String, Object?>)? browserCall,
    Future<Object?> Function(String, Map<String, dynamic>)? websocketCall,
    Future<Object?> Function(String method, String provider)? appTunnelCall,
    Future<Object?> Function(String accountId)? appTunnelReuseCall,
    ScriptInputCall? inputCall,
    Future<Object?> Function(String, Object?, Object?)? accountCall,
    ScriptScanCall? scanCall,
    ScriptDeviceInputCall? deviceInputCall,
    ScriptExecutionTurn? execution,
    bool Function()? isActive,
    Future<void>? cancellationSignal,
    String? htmlStdlib,
    void Function(String level, String message)? onLog,
    Duration wallTimeout = const Duration(seconds: 35),
    int cpuTimeoutMs = 5000,
    int memoryBytes = 64 * 1024 * 1024,
    int maxOutputBytes = 4 * 1024 * 1024,
    int maxHostCalls = 256,
    int maxRequests = 20,
    int Function()? remainingRequests,
  }) async {
    if (package.requiresUpdate) {
      throw const ScriptRunException('script_update_required');
    }
    if (execution != null && package.manifest.sdkVersion < 19) {
      throw const ScriptRunException('execution_unavailable');
    }
    if (execution?.missed == true) {
      throw const ScriptRunException('execution_missed');
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
    final queryForm = package.manifest.capability('query.controls');
    if (capability == 'query.controls' &&
        params.containsKey('load') &&
        (decl.schemaVersion != '2.1' || !isQueryFieldList(params['load']))) {
      throw const ScriptRunException('input_invalid_request');
    }
    if (capability == 'query.controls' &&
        const {'2.0', '2.1'}.contains(decl.schemaVersion)) {
      if (params.keys.any(
            (k) => !{
              'target',
              'current',
              'changed',
              if (decl.schemaVersion == '2.1') 'load',
            }.contains(k),
          ) ||
          !const {
            'grades.list',
            'classroom.available',
          }.contains(params['target']) ||
          package.manifest.capability(params['target'] as String) == null ||
          (params.containsKey('current') &&
              !isQueryFilterMap(params['current'])) ||
          (params.containsKey('changed') &&
              !isQueryFieldId(params['changed']))) {
        throw const ScriptRunException('input_invalid_request');
      }
    }
    if (const {'2.0', '2.1'}.contains(queryForm?.schemaVersion) &&
        const {'grades.list', 'classroom.available'}.contains(capability) &&
        params.containsKey('filters') &&
        !isQueryFilterMap(params['filters'])) {
      throw const ScriptRunException('input_invalid_request');
    }
    final paramsJson = jsonEncode(params);
    if (utf8.encode(paramsJson).length > 1024 * 1024) {
      throw const ScriptRunException('params_limit');
    }
    if (capability == 'web.content' &&
        (params.length != 1 ||
            !package.manifest.webContent.any(
              (page) => page.id == params['pageId'],
            ))) {
      throw const ScriptRunException('input_invalid_request');
    }
    var contentOpened = false;
    final statusOnly =
        capability == 'account.session' && params['operation'] == 'status';
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
    var devicePending = false;
    var deviceRequests = 0;
    var appTunnelPending = false;
    var appTunnelLogins = 0;
    ScriptRunException? fatal;
    void check({bool count = true}) {
      if (fatal != null) throw fatal!;
      if (!running || !(isActive?.call() ?? true)) {
        throw const ScriptRunException('invocation_cancelled');
      }
      if (count && appTunnelPending) {
        throw const ScriptRunException('input_busy');
      }
      if (count && devicePending) {
        throw const ScriptRunException('device_input_busy');
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
    qjs.setHostFunctions(
      scriptHostFunctions({
        '__script_budget': () {
          check();
          if (package.manifest.sdkVersion < 20) {
            throw const ScriptRunException('invalid_limits');
          }
          final bridge = maxRequests - requests;
          final transport = remainingRequests?.call() ?? bridge;
          return jsonEncode({
            'requests': bridge < transport ? bridge : transport,
          });
        },
        '__script_execution': (dynamic method, dynamic encoded) {
          check();
          if (package.manifest.sdkVersion < 19 || execution == null) {
            throw const ScriptRunException('execution_unavailable');
          }
          if (method is! String ||
              encoded is! String ||
              utf8.encode(encoded).length > 128 * 1024) {
            throw const ScriptRunException('execution_invalid_request');
          }
          return execution.call(method, jsonDecode(encoded));
        },
        '__script_accounts':
            (dynamic method, dynamic account, dynamic encoded) async {
              check();
              if (package.manifest.sdkVersion < 14 || accountCall == null) {
                throw const ScriptRunException('account_password_unavailable');
              }
              if (method is! String ||
                  account is! String ||
                  encoded is! String ||
                  encoded.length > 16384) {
                throw const ScriptRunException('account_invalid_request');
              }
              if (statusOnly && method != 'report') {
                throw const ScriptRunException('account_manual_login_required');
              }
              if (inputPending ||
                  scanPending ||
                  devicePending ||
                  appTunnelPending) {
                throw const ScriptRunException('input_busy');
              }
              inputPending = true;
              try {
                final result = await accountCall(
                  method,
                  account,
                  jsonDecode(encoded),
                );
                check(count: false);
                if (result is Map) {
                  for (final key in const [
                    'username',
                    'password',
                    'attemptId',
                  ]) {
                    final value = result[key];
                    if (value is String && value.isNotEmpty) {
                      knownSecrets.add(value);
                    }
                  }
                }
                return jsonEncode(result);
              } on ScriptAccountException catch (error) {
                throw ScriptRunException(error.code);
              } on ScriptRunException {
                rethrow;
              } catch (_) {
                throw const ScriptRunException('account_invalid_request');
              } finally {
                inputPending = false;
              }
            },
        '__script_app_tunnel':
            (dynamic method, dynamic provider, dynamic encoded) async {
              check();
              final options = encoded is String ? jsonDecode(encoded) : null;
              if (options is! Map<String, dynamic> ||
                  options.keys.any((k) => k != 'accountId') ||
                  (options.isNotEmpty &&
                      (method != 'login' ||
                          package.manifest.sdkVersion < 15 ||
                          options['accountId'] is! String ||
                          appTunnelReuseCall == null))) {
                throw const ScriptRunException('input_unavailable');
              }
              if (package.manifest.sdkVersion >= 16) {
                final target = capability == 'account.session'
                    ? package.manifest.accounts
                          .where((a) => a.id == params['account'])
                          .firstOrNull
                    : null;
                if ((target?.appTunnel?.service ??
                            target?.credentialReuse?.service) !=
                        provider ||
                    (method == 'login' && options.isEmpty)) {
                  throw const ScriptRunException('input_unavailable');
                }
              }
              if (options.isNotEmpty) {
                final target = package.manifest.accounts
                    .where((a) => a.id == options['accountId'])
                    .firstOrNull;
                if ((target?.appTunnel?.service ??
                            target?.credentialReuse?.service) !=
                        provider ||
                    target == null ||
                    !ScriptAccountBridge.isLoginInvocation(
                      target,
                      capability,
                      params,
                    )) {
                  throw const ScriptRunException('input_unavailable');
                }
              }
              if (package.manifest.sdkVersion < 12 ||
                  !package.manifest.appTunnels.contains(provider) ||
                  (options.isEmpty && appTunnelCall == null)) {
                throw const ScriptRunException('app_tunnel_unavailable');
              }
              if (!const ['status', 'login'].contains(method) ||
                  (statusOnly && method != 'status')) {
                throw const ScriptRunException('input_unavailable');
              }
              if (appTunnelPending ||
                  inputPending ||
                  devicePending ||
                  scanPending ||
                  (method == 'login' && ++appTunnelLogins > 1)) {
                throw const ScriptRunException('input_unavailable');
              }
              if (++requests > maxRequests) {
                fatal = const ScriptRunException('request_limit');
                throw fatal!;
              }
              appTunnelPending = true;
              try {
                final value = options.isNotEmpty
                    ? await appTunnelReuseCall!(options['accountId'] as String)
                    : await appTunnelCall!(
                        method as String,
                        provider as String,
                      );
                check(count: false);
                return jsonEncode(value);
              } finally {
                appTunnelPending = false;
              }
            },
        '__script_websocket': (dynamic method, dynamic encoded) async {
          check();
          if (package.manifest.sdkVersion < 9 ||
              package.manifest.websocketNetwork.origins.isEmpty ||
              websocketCall == null) {
            throw const ScriptRunException('websocket_unavailable');
          }
          if (method is! String ||
              encoded is! String ||
              encoded.length > 400000) {
            throw const ScriptRunException('websocket_invalid_request');
          }
          try {
            final args = jsonDecode(encoded);
            if (args is! Map<String, dynamic>) {
              throw const ScriptRunException('websocket_invalid_request');
            }
            if (method == 'open') {
              final uri = args['url'] is String
                  ? Uri.tryParse(args['url'] as String)
                  : null;
              if (uri == null ||
                  uri.scheme != 'wss' ||
                  uri.hasFragment ||
                  !package.manifest.websocketNetwork.allowsUrl(
                    uri.replace(scheme: 'https'),
                  )) {
                throw const ScriptRunException('network_denied');
              }
            }
            final result = await websocketCall(method, args);
            check(count: false);
            return jsonEncode(result);
          } on ScriptRunException {
            rethrow;
          } catch (_) {
            throw const ScriptRunException('websocket_failed');
          }
        },
        '__script_device_input': (dynamic kind, dynamic argumentCount) async {
          check();
          if (statusOnly) throw const ScriptRunException('input_unavailable');
          if (package.manifest.sdkVersion < 10 ||
              deviceInputCall == null ||
              !package.manifest.deviceInputs.contains(kind)) {
            throw const ScriptRunException('device_input_unavailable');
          }
          if (argumentCount != 0 || !scriptDeviceInputKinds.contains(kind)) {
            throw const ScriptRunException('device_input_invalid_request');
          }
          if (inputPending || scanPending || devicePending) {
            throw const ScriptRunException('device_input_busy');
          }
          if (++deviceRequests > 4) {
            throw const ScriptRunException('device_input_limit');
          }
          devicePending = true;
          try {
            final raw = await deviceInputCall(
              kind as String,
              () => running && (isActive?.call() ?? true),
            );
            check(count: false);
            final result = validateDeviceInput(kind, raw);
            if (result != null) {
              if (kind == 'location') {
                for (final value in result.values) {
                  knownSecrets.add(value.toString());
                }
              } else {
                knownSecrets.add(
                  base64Encode((result['bytes'] as List).cast<int>()),
                );
                knownSecrets.add(jsonEncode(result['bytes']));
              }
            }
            return jsonEncode(result);
          } on ScriptDeviceInputException catch (error) {
            throw ScriptRunException(error.code);
          } on ScriptRunException {
            rethrow;
          } catch (_) {
            throw const ScriptRunException('device_input_unavailable');
          } finally {
            devicePending = false;
          }
        },
        '__script_scan': (dynamic argumentCount) async {
          check();
          if (statusOnly) throw const ScriptRunException('input_unavailable');
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
          if (statusOnly) throw const ScriptRunException('input_unavailable');
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
                if (value is String && value.isNotEmpty) {
                  knownSecrets.add(value);
                }
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
          if (init['body'] != null &&
              init['body'] is! String &&
              package.manifest.sdkVersion < 10) {
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
          } on ScriptRunException catch (error) {
            if (package.manifest.sdkVersion >= 20 &&
                error.code.endsWith('_limit')) {
              fatal = error;
            }
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
                      throw const ScriptRunException(
                        'invalid_credential_value',
                      );
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
          if (statusOnly) throw const ScriptRunException('input_unavailable');
          if (!package.manifest.browser || browserCall == null) {
            throw const ScriptRunException('browser_unavailable');
          }
          if (method is! String || args is! Map) {
            throw const ScriptRunException('invalid_browser_operation');
          }
          if (method == 'openContent' || method == 'content') {
            if (package.manifest.sdkVersion < 14 ||
                package.manifest.webContent.isEmpty ||
                capability != 'web.content') {
              throw const ScriptRunException('browser_content_undeclared');
            }
            if (method == 'openContent' &&
                (args.length != 1 || args['id'] != params['pageId'])) {
              throw const ScriptRunException('browser_content_undeclared');
            }
            if (method == 'content' && !contentOpened) {
              throw const ScriptRunException('browser_content_not_open');
            }
          }
          if (capability == 'web.content' &&
              !const {'openContent', 'content', 'setBusy'}.contains(method)) {
            throw const ScriptRunException(
              'browser_content_evaluate_forbidden',
            );
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
            if (method == 'openContent') contentOpened = true;
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
              'browser_closed' ||
              'browser_unavailable' ||
              'browser_content_unavailable' ||
              'browser_content_undeclared' ||
              'browser_content_invalid_operation' ||
              'browser_content_evaluate_forbidden' ||
              'browser_content_remote_forbidden' ||
              'browser_content_cookies_forbidden' ||
              'browser_content_not_open' => error.code,
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
          clean = clean.replaceAll(RegExp(r'(?:https?|wss)://[^\s]+'), '[url]');
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
      }),
    );

    final cancelled = Completer<Object?>();
    cancellationSignal?.then((_) {
      if (running && !cancelled.isCompleted) {
        cancelled.completeError(
          const ScriptRunException('invocation_cancelled'),
        );
      }
    });
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
          scriptRuntimeBootstrap(
            execution: execution,
            capability: capability,
            sdkVersion: package.manifest.sdkVersion,
            packageId: package.manifest.id,
            paramsJson: paramsJson,
            locale: package.manifest.sdkVersion >= 13
                ? (normalizeScriptLocale(locale) ?? 'zh')
                : null,
            localization: package.manifest.localization,
            browser: package.manifest.browser,
            browserBusy: package.manifest.sdkVersion >= 4,
            webContent:
                package.manifest.sdkVersion >= 14 &&
                package.manifest.webContent.isNotEmpty,
            input: package.manifest.sdkVersion >= 3,
            accounts: package.manifest.sdkVersion >= 14,
            websocket:
                package.manifest.sdkVersion >= 9 &&
                package.manifest.websocketNetwork.origins.isNotEmpty,
            deviceInputs: package.manifest.sdkVersion >= 10,
            appTunnel:
                package.manifest.sdkVersion >= 12 &&
                package.manifest.appTunnels.isNotEmpty,
            scanner:
                package.manifest.sdkVersion >= 8 && package.manifest.scanner,
            maxOutputBytes: maxOutputBytes,
          ),
        );
        await qjs.evaluate(
          "import * as adapter from 'adapter'; globalThis.__scriptCaps = adapter.capabilities; globalThis.__scriptHandlers = adapter.handlers;",
          name: '<script-load>',
          evalFlags: JSEvalFlag.MODULE,
        );
        check(count: false);
        return qjs.evaluate('globalThis.__scriptInvoke()');
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
        final error = outcome is Map ? outcome['error'] : null;
        throw ScriptRunException(
          error is Map && error['code'] is String
              ? error['code'] as String
              : 'adapter_failed',
          businessCode:
              package.manifest.sdkVersion >= 17 &&
                  error is Map &&
                  error['code'] == 'script_business_error' &&
                  isScriptBusinessCode(
                    error['businessCode'],
                    package.manifest.id,
                  )
              ? error['businessCode'] as String
              : null,
        );
      }
      final output = outcome['data'];
      if (capability == 'query.controls' &&
          const {'2.0', '2.1'}.contains(decl.schemaVersion)) {
        if (utf8.encode(jsonEncode(output)).length > 128 * 1024) {
          throw const ScriptRunException('output_limit');
        }
        if (output is! Map || output['target'] != params['target']) {
          throw const ScriptRunException('schema_validation_failed');
        }
      }
      if (capability == 'web.content' &&
          (output is! Map || output['pageId'] != params['pageId'])) {
        throw const ScriptRunException('schema_validation_failed');
      }
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
