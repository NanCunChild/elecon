/// ADR-090: a durable, host-only account incarnation; never a school credential.
library;

import 'dart:math';

import '../credential/store.dart';
import '../credential/types.dart';

class ScheduleWidgetIdentityStore {
  const ScheduleWidgetIdentityStore(this.store);
  final CredentialStore store;
  static const type = 'schedule-widget-identity';

  String token(String schoolId) {
    final ref = 'schedule-widget-identity:$schoolId';
    final existing = store
        .list()
        .where((entry) => entry.ref == ref)
        .firstOrNull;
    if (existing?.type == type &&
        existing?.schoolId == schoolId &&
        existing?.status == CredentialStatus.active &&
        RegExp(r'^[a-f0-9]{64}$').hasMatch(existing!.value)) {
      return existing.value;
    }
    final random = Random.secure();
    final value = List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    store.put(
      CredentialEntry(
        ref: ref,
        schoolId: schoolId,
        type: type,
        scope: const [],
        value: value,
        acquiredAt: DateTime.now().millisecondsSinceEpoch,
        expiresAt: null,
        status: CredentialStatus.active,
      ),
    );
    return value;
  }

  Set<String> clearSchool(String schoolId) {
    final refs = {
      for (final entry in store.list())
        if (entry.type == type && entry.schoolId == schoolId) entry.ref,
    };
    for (final ref in refs) {
      store.delete(ref);
    }
    return refs;
  }
}
