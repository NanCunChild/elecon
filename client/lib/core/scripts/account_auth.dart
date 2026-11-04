/// SDK14: scoped password attempts and fixed account events (ADR-072).
library;

import 'dart:convert';
import 'dart:math';

import '../credential/store.dart';
import '../credential/types.dart';
import 'manifest.dart';

class ScriptAccountException implements Exception {
  const ScriptAccountException(this.code);
  final String code;
  @override
  String toString() => 'ScriptAccountException($code)';
}

/// The UI sees a name and storage state, never the saved password.
bool _alwaysActive() => true;

class ScriptPasswordPrompt {
  const ScriptPasswordPrompt({
    required this.accountName,
    required this.username,
    required this.hasSavedPassword,
    required this.blocked,
    required this.allowWeb,
    this.isActive = _alwaysActive,
    this.instructions,
    this.tunnel,
  });
  final String accountName, username;
  final bool hasSavedPassword, blocked, allowWeb;
  final bool Function() isActive;
  final String? instructions;
  final ScriptAppTunnel? tunnel;
}

class ScriptPasswordInput {
  const ScriptPasswordInput.saved()
    : useSaved = true,
      useWeb = false,
      username = '',
      password = '',
      remember = true;
  const ScriptPasswordInput.web()
    : useSaved = false,
      useWeb = true,
      username = '',
      password = '',
      remember = false;
  const ScriptPasswordInput({
    required this.username,
    required this.password,
    required this.remember,
  }) : useSaved = false,
       useWeb = false;
  final bool useSaved, useWeb, remember;
  final String username, password;
}

typedef ScriptPasswordCall =
    Future<ScriptPasswordInput?> Function(ScriptPasswordPrompt request);

class ScriptAccountMetadata {
  const ScriptAccountMetadata({
    required this.username,
    required this.blocked,
    required this.reason,
  });
  final String username, reason;
  final bool blocked;
}

class ScriptAccountEvent {
  const ScriptAccountEvent({
    required this.accountId,
    required this.status,
    required this.reason,
    required this.scriptId,
    required this.digest,
    required this.observedAt,
  });
  final String accountId, status, reason, scriptId, digest;
  final DateTime observedAt;
  List<String> get actions => switch (reason) {
    'credentialsRejected' => const ['updateCredentials', 'interactiveLogin'],
    'accountDisabled' => const ['interactiveLogin'],
    'primaryExpired' ||
    'interactionRequired' ||
    'recoveryBlocked' => const ['interactiveLogin', 'updateCredentials'],
    'networkUnknown' => const ['retry'],
    _ => const [],
  };
}

/// Entries live in the same H/S/M backend as school cookies. Reserved refs do
/// not turn namespace into an independent sandbox for same-school trusted code.
class ScriptAccountStore {
  ScriptAccountStore(this.store, {DateTime Function()? now})
    : now = now ?? DateTime.now;
  static const type = 'script-account-password';
  final CredentialStore store;
  final DateTime Function() now;
  static final _random = Random.secure();
  static String newId() => base64Url
      .encode(List<int>.generate(24, (_) => _random.nextInt(256)))
      .replaceAll('=', '');
  String ref(String schoolId, String namespace) =>
      'script-account:$schoolId:$namespace';
  CredentialEntry? entry(String schoolId, String namespace) {
    final result = store
        .list()
        .where((entry) => entry.ref == ref(schoolId, namespace))
        .firstOrNull;
    if (result != null &&
        (result.schoolId != schoolId || result.type != type)) {
      throw const ScriptAccountException('account_storage_invalid');
    }
    return result;
  }

  Map<String, dynamic>? read(String schoolId, String namespace) {
    final stored = entry(schoolId, namespace);
    if (stored == null) return null;
    if (stored.status != CredentialStatus.active ||
        (stored.expiresAt != null &&
            stored.expiresAt! <= now().millisecondsSinceEpoch)) {
      throw const ScriptAccountException('account_storage_invalid');
    }
    try {
      final value = jsonDecode(stored.value);
      if (value is! Map<String, dynamic> ||
          value['version'] != 1 ||
          value['revision'] is! String ||
          !RegExp(
            r'^[A-Za-z0-9_-]{32}$',
          ).hasMatch(value['revision'] as String) ||
          !_text(value['username'], 256) ||
          !_text(value['password'], 4096) ||
          value['blocked'] is! bool ||
          !const {
            'verified',
            'recoveryBlocked',
            'interactionRequired',
            'credentialsRejected',
            'accountDisabled',
            'unknown',
          }.contains(value['reason']) ||
          value.length != 6) {
        throw const FormatException();
      }
      return value;
    } catch (_) {
      throw const ScriptAccountException('account_storage_invalid');
    }
  }

  ScriptAccountMetadata? metadata(String schoolId, String namespace) {
    final value = read(schoolId, namespace);
    return value == null
        ? null
        : ScriptAccountMetadata(
            username: value['username'] as String,
            blocked: value['blocked'] as bool,
            reason: value['reason'] as String,
          );
  }

  void write(String schoolId, String namespace, Map<String, dynamic> value) {
    store.put(
      CredentialEntry(
        ref: ref(schoolId, namespace),
        schoolId: schoolId,
        type: type,
        scope: const [],
        value: jsonEncode(value),
        acquiredAt: now().millisecondsSinceEpoch,
        expiresAt: null,
        status: CredentialStatus.active,
        sensitivity: CredentialSensitivity.master,
      ),
    );
  }

  /// Compare actual backend records after flushing. A logout/deletion/newer
  /// write wins over this operation; rollback must never revive its old secret.
  Future<void> commit(
    String schoolId,
    String namespace,
    Map<String, dynamic>? value,
    Future<void> Function() persist,
    bool Function() isActive,
  ) async {
    if (!isActive()) throw const ScriptAccountException('invocation_cancelled');
    final previous = entry(schoolId, namespace);
    if (value == null) {
      store.delete(ref(schoolId, namespace));
    } else {
      write(schoolId, namespace, value);
    }
    final written = entry(schoolId, namespace);
    try {
      await persist();
      if (!isActive()) {
        throw const ScriptAccountException('invocation_cancelled');
      }
      if (!identical(entry(schoolId, namespace), written)) {
        throw const ScriptAccountException('account_attempt_invalid');
      }
    } catch (error) {
      if (identical(entry(schoolId, namespace), written) &&
          !identical(previous, written)) {
        if (previous != null && (isActive() || written != null)) {
          store.put(previous);
        } else {
          store.delete(ref(schoolId, namespace));
        }
      }
      try {
        await persist();
      } catch (_) {
        /* Keep the fixed error below. */
      }
      if (error is ScriptAccountException) rethrow;
      throw const ScriptAccountException('account_storage_failed');
    }
  }

  /// Claim before returning a secret. The failed durable write remains blocked
  /// in memory, since storage completion may have been ambiguous.
  Future<Map<String, dynamic>> claimAutomatic(
    String schoolId,
    String namespace,
    Future<void> Function() persist,
  ) async {
    final saved = read(schoolId, namespace);
    if (saved == null || saved['blocked'] == true) {
      throw const ScriptAccountException('account_recovery_blocked');
    }
    final claimed = {...saved, 'blocked': true, 'reason': 'recoveryBlocked'};
    write(schoolId, namespace, claimed);
    try {
      await persist();
    } catch (_) {
      throw const ScriptAccountException('account_storage_failed');
    }
    return claimed;
  }

  static bool _text(Object? value, int max) =>
      value is String &&
      value.isNotEmpty &&
      value.length <= max &&
      !value.codeUnits.any((u) => u < 32 || u == 127);
}

class _PasswordAttempt {
  _PasswordAttempt({
    required this.id,
    required this.account,
    required this.username,
    required this.password,
    required this.remember,
    required this.automatic,
    required this.revision,
    required this.usedSaved,
  });
  final String id, account, username, password;
  final String? revision;
  final bool remember, automatic, usedSaved;
}

/// One instance per invocation, discarded on return/cancellation. Script calls
/// cannot choose a Profile, school, digest or arbitrary storage reference.
class ScriptAccountBridge {
  ScriptAccountBridge({
    required this.package,
    required this.capability,
    required this.params,
    required this.store,
    required this.persist,
    required this.isActive,
    required this.interactive,
    this.passwordCall,
    this.onEvent,
    this.silentBrowserAvailable = false,
  });
  final ScriptPackage package;
  final String capability;
  final Map<String, dynamic> params;
  final ScriptAccountStore store;
  final Future<void> Function() persist;
  final bool Function() isActive;
  final bool interactive, silentBrowserAvailable;
  final ScriptPasswordCall? passwordCall;
  final void Function(ScriptAccountEvent)? onEvent;
  final Map<String, _PasswordAttempt> _attempts = {};
  final Set<String> _requested = {};
  bool _pending = false;
  bool _open = true;
  void close() {
    _open = false;
  }

  int _events = 0;

  void _check() {
    if (!_open || !isActive()) {
      throw const ScriptAccountException('invocation_cancelled');
    }
  }

  ScriptAccount _account(Object? id) {
    _check();
    final account = package.manifest.accounts
        .where((a) => a.id == id)
        .firstOrNull;
    if (package.manifest.sdkVersion < 14 ||
        account == null ||
        (!account.capabilities.contains(capability) &&
            account.loginCapability != capability &&
            account.statusCapability != capability)) {
      throw const ScriptAccountException('account_not_declared');
    }
    // account.session must not report or borrow another declared account.
    if (capability == 'account.session' && params['account'] != account.id) {
      throw const ScriptAccountException('account_not_declared');
    }
    return account;
  }

  static bool isLoginInvocation(
    ScriptAccount account,
    String capability,
    Map<String, dynamic> params,
  ) =>
      capability == account.loginCapability &&
      _sameJson(params, account.loginParams);
  bool _manualLogin(ScriptAccount account) =>
      interactive && isLoginInvocation(account, capability, params);
  static bool _sameJson(Object? left, Object? right) {
    if (left is Map && right is Map) {
      return left.length == right.length &&
          left.keys.every(
            (key) => right.containsKey(key) && _sameJson(left[key], right[key]),
          );
    }
    if (left is List && right is List) {
      return left.length == right.length &&
          List.generate(
            left.length,
            (i) => i,
          ).every((i) => _sameJson(left[i], right[i]));
    }
    return left == right;
  }

  static Map<String, dynamic> _object(Object? value, Set<String> keys) {
    if (value is! Map<String, dynamic> ||
        value.keys.any((k) => !keys.contains(k))) {
      throw const ScriptAccountException('account_invalid_request');
    }
    return value;
  }

  Future<Object?> call(String method, Object? accountId, Object? raw) async {
    final account = _account(accountId);
    if (method == 'report') {
      final data = _object(raw, {'status', 'reason'});
      _report(account, data['status'], data['reason']);
      return null;
    }
    if (account.authentication == null) {
      throw const ScriptAccountException('account_password_unavailable');
    }
    if (method == 'password') {
      final data = _object(raw, {'mode'});
      if (data.length != 1 ||
          !const ['manual', 'automatic'].contains(data['mode'])) {
        throw const ScriptAccountException('account_invalid_request');
      }
      return _password(account, automatic: data['mode'] == 'automatic');
    }
    if (method == 'completePassword') {
      final data = _object(raw, {'attemptId', 'outcome'});
      if (data.length != 2 ||
          data['attemptId'] is! String ||
          !const [
            'authenticated',
            'interactionRequired',
            'credentialsRejected',
            'accountDisabled',
            'unknown',
          ].contains(data['outcome'])) {
        throw const ScriptAccountException('account_invalid_request');
      }
      return _complete(
        account,
        data['attemptId'] as String,
        data['outcome'] as String,
      );
    }
    throw const ScriptAccountException('account_invalid_request');
  }

  Future<Object?> _password(
    ScriptAccount account, {
    required bool automatic,
  }) async {
    if (_pending || !_requested.add(account.id)) {
      throw const ScriptAccountException('account_attempt_limit');
    }
    _pending = true;
    try {
      final namespace = account.authentication!.namespace;
      var saved = store.read(package.manifest.schoolId, namespace);
      if (automatic &&
          (!account.authentication!.silentWeb || !silentBrowserAvailable)) {
        throw const ScriptAccountException('account_silent_unavailable');
      }
      if (!automatic && !_manualLogin(account)) {
        throw const ScriptAccountException('account_manual_login_required');
      }
      if (automatic && (saved == null || saved['blocked'] == true)) {
        _report(
          account,
          'expired',
          saved == null ? 'interactionRequired' : 'recoveryBlocked',
        );
        throw const ScriptAccountException('account_recovery_blocked');
      }
      ScriptPasswordInput? input;
      if (automatic) {
        input = const ScriptPasswordInput.saved();
      } else {
        if (passwordCall == null) {
          throw const ScriptAccountException('account_password_unavailable');
        }
        input = await passwordCall!(
          ScriptPasswordPrompt(
            accountName: account.name,
            username: saved?['username'] as String? ?? '',
            hasSavedPassword: saved != null,
            blocked: saved?['blocked'] == true,
            allowWeb: account.authentication!.interactiveWeb,
            isActive: () => _open && isActive(),
          ),
        );
        _check();
        if (input == null) return null;
        if (input.useWeb) {
          if (!account.authentication!.interactiveWeb) {
            throw const ScriptAccountException('account_invalid_input');
          }
          throw const ScriptAccountException('account_interactive_fallback');
        }
        final latest = store.read(package.manifest.schoolId, namespace);
        if (latest?['revision'] != saved?['revision']) {
          throw const ScriptAccountException('account_attempt_invalid');
        }
        saved = latest;
      }
      if (input.useSaved && saved == null) {
        throw const ScriptAccountException('account_invalid_input');
      }
      final username = input.useSaved
          ? saved!['username'] as String
          : input.username.trim();
      final password = input.useSaved
          ? saved!['password'] as String
          : input.password;
      if (!ScriptAccountStore._text(username, 256) ||
          !ScriptAccountStore._text(password, 4096)) {
        throw const ScriptAccountException('account_invalid_input');
      }
      if (input.useSaved) {
        // Synchronous in-memory claim happens before the first await. Failure
        // retains it, so an uncertain durable write never permits a new attempt.
        if (automatic) {
          saved = await store.claimAutomatic(
            package.manifest.schoolId,
            namespace,
            persist,
          );
        } else {
          saved = {...saved!, 'blocked': true, 'reason': 'recoveryBlocked'};
          store.write(package.manifest.schoolId, namespace, saved);
          try {
            await persist();
          } catch (_) {
            throw const ScriptAccountException('account_storage_failed');
          }
        }
        _check();
      }
      final attempt = _PasswordAttempt(
        id: ScriptAccountStore.newId(),
        account: account.id,
        username: username,
        password: password,
        remember: input.remember,
        automatic: automatic,
        revision: saved?['revision'] as String?,
        usedSaved: input.useSaved,
      );
      _attempts[attempt.id] = attempt;
      return {
        'attemptId': attempt.id,
        'username': username,
        'password': password,
      };
    } finally {
      _pending = false;
    }
  }

  Future<Object?> _complete(
    ScriptAccount account,
    String id,
    String outcome,
  ) async {
    final attempt = _attempts.remove(id);
    if (attempt == null || attempt.account != account.id) {
      throw const ScriptAccountException('account_attempt_invalid');
    }
    final namespace = account.authentication!.namespace;
    final schoolId = package.manifest.schoolId;
    final current = store.read(schoolId, namespace);
    if (current?['revision'] != attempt.revision) {
      throw const ScriptAccountException('account_attempt_invalid');
    }
    if (outcome == 'authenticated' && attempt.remember) {
      await store.commit(
        schoolId,
        namespace,
        {
          'version': 1,
          'revision': attempt.usedSaved
              ? attempt.revision
              : ScriptAccountStore.newId(),
          'username': attempt.username,
          'password': attempt.password,
          'blocked': attempt.automatic,
          'reason': attempt.automatic ? 'recoveryBlocked' : 'verified',
        },
        persist,
        () => _open && isActive(),
      );
    } else if (outcome != 'authenticated' &&
        attempt.usedSaved &&
        current != null) {
      store.write(schoolId, namespace, {
        ...current,
        'blocked': true,
        'reason': outcome,
      });
      try {
        await persist();
      } catch (_) {
        throw const ScriptAccountException('account_storage_failed');
      }
      _check();
    }
    _report(
      account,
      outcome == 'authenticated'
          ? 'authenticated'
          : outcome == 'unknown'
          ? 'unknown'
          : 'expired',
      outcome == 'authenticated'
          ? 'verified'
          : outcome == 'unknown'
          ? 'networkUnknown'
          : outcome,
    );
    return null;
  }

  void _report(ScriptAccount account, Object? status, Object? reason) {
    _check();
    const allowed = {
      'authenticated': {'verified'},
      'signedOut': {'signedOut'},
      'expired': {
        'primaryExpired',
        'interactionRequired',
        'credentialsRejected',
        'accountDisabled',
        'recoveryBlocked',
      },
      'unknown': {'networkUnknown'},
    };
    if (status is! String ||
        reason is! String ||
        allowed[status]?.contains(reason) != true) {
      throw const ScriptAccountException('account_invalid_event');
    }
    if (++_events > 8) {
      throw const ScriptAccountException('account_event_limit');
    }
    onEvent?.call(
      ScriptAccountEvent(
        accountId: account.id,
        status: status,
        reason: reason,
        scriptId: package.manifest.id,
        digest: package.digest,
        observedAt: store.now(),
      ),
    );
  }
}
