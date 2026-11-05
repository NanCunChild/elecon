import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/credential/hardware_keystore.dart';
import 'package:elecon/core/credential/hardware_secure_store.dart';
import 'package:elecon/core/credential/types.dart';
import 'package:elecon/session/session_controller.dart';

import 'school_fixture.dart';

/// Synthetic reversible key wrapper; it deliberately provides no security.
class RecoverableHardware implements HardwareKeyStore {
  bool unavailable = false;
  int probes = 0;
  int wraps = 0;
  int unwraps = 0;
  Completer<void>? release;
  Completer<void>? entered;

  @override
  Future<bool> isAvailable() async {
    probes++;
    return !unavailable;
  }

  @override
  Future<Uint8List> wrapDek(List<int> dek) async {
    wraps++;
    return Uint8List.fromList([for (final byte in dek) byte ^ 0xa5]);
  }

  @override
  Future<Uint8List> unwrapDek(List<int> wrapped) async {
    unwraps++;
    if (entered case final event?) {
      if (!event.isCompleted) event.complete();
    }
    await release?.future;
    if (unavailable) throw StateError('synthetic_hardware_unavailable');
    return Uint8List.fromList([for (final byte in wrapped) byte ^ 0xa5]);
  }
}

Future<InMemoryBlobStore> seedProtectedStore(
  RecoverableHardware hardware,
) async {
  final blobs = InMemoryBlobStore();
  final store = await HardwareSecureStore.open(hardware, blobs);
  store.put(
    CredentialEntry(
      ref: 'synthetic-session',
      schoolId: testSchool().id,
      type: 'cookie',
      scope: const [],
      value: 'SYNTHETIC_PROTECTED_CREDENTIAL',
      acquiredAt: 1,
      expiresAt: null,
      status: CredentialStatus.active,
    ),
  );
  await store.flush();
  await blobs.write(
    'session.json',
    utf8.encode(jsonEncode({'selectedSchoolId': testSchool().id})),
  );
  return blobs;
}

SessionController protectedSession(
  BlobStore blobs,
  HardwareKeyStore hardware,
) => SessionController(
  hardware: hardware,
  blobStoreProvider: () async => blobs,
  initialSchools: [testSchool()],
);
