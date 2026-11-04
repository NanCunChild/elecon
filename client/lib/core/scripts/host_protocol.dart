/// ADR-081: one typed, text-independent host failure protocol.
library;

import 'dart:convert';

class ScriptRunException implements Exception {
  const ScriptRunException(this.code, {this.businessCode});
  final String code;

  /// SDK17 school-specific diagnostic identity, never an automatic retry policy.
  final String? businessCode;
  @override
  String toString() => 'ScriptRunException($code)';
}

bool isScriptBusinessCode(Object? value, String packageId) =>
    value is String &&
    value.startsWith('$packageId:') &&
    RegExp(
      r'^[a-z][a-z0-9_]{0,63}$',
    ).hasMatch(value.substring(packageId.length + 1));

// Only these identifiers may cross the native bridge. Native exception messages
// and toString() never participate in classification, including typed errors.
const scriptHostErrorCodes = <String>{
  'account_attempt_invalid',
  'account_attempt_limit',
  'account_event_limit',
  'account_interactive_fallback',
  'account_invalid_event',
  'account_invalid_input',
  'account_invalid_request',
  'account_manual_login_required',
  'account_not_declared',
  'account_password_unavailable',
  'account_recovery_blocked',
  'account_silent_unavailable',
  'account_storage_failed',
  'account_storage_invalid',
  'adapter_failed',
  'app_tunnel_unavailable',
  'authentication_required',
  'authentication_timeout',
  'browser_closed',
  'browser_content_cookies_forbidden',
  'browser_content_evaluate_forbidden',
  'browser_content_invalid_operation',
  'browser_content_not_open',
  'browser_content_remote_forbidden',
  'browser_content_unavailable',
  'browser_content_undeclared',
  'browser_failed',
  'browser_navigation_blocked',
  'browser_navigation_changed',
  'browser_not_loaded',
  'browser_result_limit',
  'browser_unavailable',
  'capability_missing',
  'capability_not_declared',
  'configuration_required',
  'credential_descriptor_conflict',
  'device_input_busy',
  'device_input_invalid_request',
  'device_input_invalid_result',
  'device_input_limit',
  'device_input_permission_denied',
  'device_input_timeout',
  'device_input_unavailable',
  'execution_failed',
  'fetch_failed',
  'host_call_limit',
  'host_failed',
  'identity_inactive',
  'identity_mismatch',
  'input_busy',
  'input_cancelled',
  'input_invalid_request',
  'input_invalid_result',
  'input_limit',
  'input_required_card_number',
  'input_required_student_id',
  'input_unavailable',
  'invalid_browser_operation',
  'invalid_credential_identity',
  'invalid_credential_key',
  'invalid_credential_namespace',
  'invalid_credential_operation',
  'invalid_credential_options',
  'invalid_credential_value',
  'invalid_fetch',
  'invalid_limits',
  'invocation_cancelled',
  'localization_invalid_arguments',
  'localization_invalid_key',
  'module_not_available',
  'network_denied',
  'non_json_output',
  'output_limit',
  'params_limit',
  'request_body_limit',
  'request_limit',
  'scanner_busy',
  'scanner_invalid_request',
  'scanner_invalid_result',
  'scanner_limit',
  'scanner_permission_denied',
  'scanner_unavailable',
  'schema_unsupported',
  'schema_validation_failed',
  'script_business_error',
  'script_update_required',
  'source_response_invalid',
  'unsupported_encoding',
  'wall_timeout',
  'websocket_failed',
  'websocket_invalid_request',
  'websocket_unavailable',
};

String _category(String code) {
  if (code == 'invocation_cancelled' || code == 'input_cancelled') {
    return 'cancelled';
  }
  if (code.endsWith('_timeout')) return 'timeout';
  if (code == 'network_denied') return 'permission';
  if (code == 'authentication_required' ||
      code == 'account_manual_login_required') {
    return 'authentication';
  }
  if (code == 'configuration_required') return 'configuration';
  if (code.endsWith('_limit')) return 'resource';
  if (code.startsWith('invalid_') || code.endsWith('_invalid_request')) {
    return 'input';
  }
  return 'internal';
}

/// Preserve each callback's arity for the isolate bridge, and serialize exactly
/// one envelope. Existing JSON-valued ports retain their value encoding inside
/// the envelope; consumers decode it once after the common protocol succeeds.
Map<String, Function> scriptHostFunctions(Map<String, Function> callbacks) {
  Future<String> invoke(String name, List<Object?> arguments) async {
    try {
      final value = await Function.apply(callbacks[name]!, arguments);
      return jsonEncode({'ok': true, 'value': value});
    } catch (error) {
      final code =
          error is ScriptRunException &&
              scriptHostErrorCodes.contains(error.code)
          ? error.code
          : 'host_failed';
      return jsonEncode({
        'ok': false,
        'error': {'code': code, 'category': _category(code)},
      });
    }
  }

  return callbacks.map((name, callback) {
    final count = switch (name) {
      '__script_credentials' => 4,
      '__script_accounts' || '__script_app_tunnel' => 3,
      '__script_scan' || '__script_input' => 1,
      _ => 2,
    };
    final Function wrapped = switch (count) {
      1 => (dynamic a) => invoke(name, [a]),
      2 => (dynamic a, dynamic b) => invoke(name, [a, b]),
      3 => (dynamic a, dynamic b, dynamic c) => invoke(name, [a, b, c]),
      _ => (dynamic a, dynamic b, dynamic c, dynamic d) => invoke(name, [
        a,
        b,
        c,
        d,
      ]),
    };
    return MapEntry(name, wrapped);
  });
}
