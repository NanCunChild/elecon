/// H 硬件档凭证存储（ADR-012 §2.8）。
///
/// 整库 AES-256-GCM AEAD；DEK 由 [HardwareKeyStore] wrap 后落盘，
/// KEK 私钥/对称密钥永不出硬件。条目登记 `protection: hardware`。
///
/// 🔒 红线 #1 承重路径。AI 起草、须人工 + 安全清单审阅后合并。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'aead.dart';
import 'blob_store.dart';
import 'hardware_keystore.dart';
import 'secure_store.dart';
import 'types.dart';

const String _wrappedDekBlob = 'store.dek.wrapped';
const String _storeBlob = 'store.enc';

class HardwareSecureStore implements SecureStore {
  HardwareSecureStore._(this._aead, this._blobs, this._hardware);

  final Aead _aead;
  final BlobStore _blobs;
  final HardwareKeyStore _hardware;
  final Map<String, CredentialEntry> _entries = {};
  Future<void> _persistChain = Future<void>.value();

  /// 是否已存在 H 档（据 wrapped DEK blob）。
  static Future<bool> hasPersisted(BlobStore blobs) async =>
      (await blobs.read(_wrappedDekBlob)) != null;

  static Future<HardwareSecureStore> open(
    HardwareKeyStore hardware,
    BlobStore blobs,
  ) async {
    final dek = await _loadOrCreateDek(hardware, blobs);
    final store = HardwareSecureStore._(Aes256GcmAead(dek), blobs, hardware);
    await store._load();
    return store;
  }

  static Future<List<int>> _loadOrCreateDek(
    HardwareKeyStore hardware,
    BlobStore blobs,
  ) async {
    final wrapped = await blobs.read(_wrappedDekBlob);
    if (wrapped != null) {
      return hardware.unwrapDek(wrapped);
    }
    final rnd = Random.secure();
    final dek =
        Uint8List.fromList(List<int>.generate(32, (_) => rnd.nextInt(256)));
    final w = await hardware.wrapDek(dek);
    await blobs.write(_wrappedDekBlob, w);
    return dek;
  }

  Future<void> _load() async {
    final sealed = await _blobs.read(_storeBlob);
    if (sealed == null) return;
    final clear = await _aead.open(sealed);
    final json = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
    for (final e in (json['entries'] as List)) {
      final entry = _entryFromJson(e as Map<String, dynamic>);
      _entries[entry.ref] = entry;
    }
  }

  void _schedulePersist() {
    _persistChain = _persistChain.then((_) => _persist());
  }

  Future<void> _persist() async {
    final json = jsonEncode({
      'entries': _entries.values.map(_entryToJson).toList(),
    });
    final sealed = await _aead.seal(utf8.encode(json));
    await _blobs.write(_storeBlob, sealed);
  }

  Future<void> flush() => _persistChain;

  @override
  void put(CredentialEntry entry) {
    _entries[entry.ref] =
        _withProtection(entry, CredentialProtection.hardware);
    _schedulePersist();
  }

  @override
  CredentialEntry? get(String ref) => _entries[ref];

  @override
  void delete(String ref) {
    _entries.remove(ref);
    _schedulePersist();
  }

  @override
  List<CredentialEntry> list() => _entries.values.toList();
}

Map<String, dynamic> _entryToJson(CredentialEntry e) => {
      'ref': e.ref,
      'schoolId': e.schoolId,
      'type': e.type,
      'scope': e.scope,
      'value': e.value,
      'acquiredAt': e.acquiredAt,
      'expiresAt': e.expiresAt,
      'status': e.status.name,
      'sensitivity': e.sensitivity.name,
      'protection': e.protection.name,
    };

CredentialEntry _entryFromJson(Map<String, dynamic> j) => CredentialEntry(
      ref: j['ref'] as String,
      schoolId: j['schoolId'] as String,
      type: j['type'] as String,
      scope: (j['scope'] as List).cast<String>(),
      value: j['value'] as String,
      acquiredAt: j['acquiredAt'] as int,
      expiresAt: j['expiresAt'] as int?,
      status: CredentialStatus.values.byName(j['status'] as String),
      sensitivity:
          CredentialSensitivity.values.byName(j['sensitivity'] as String),
      protection:
          CredentialProtection.values.byName(j['protection'] as String),
    );

CredentialEntry _withProtection(CredentialEntry e, CredentialProtection p) =>
    CredentialEntry(
      ref: e.ref,
      schoolId: e.schoolId,
      type: e.type,
      scope: e.scope,
      value: e.value,
      acquiredAt: e.acquiredAt,
      expiresAt: e.expiresAt,
      status: e.status,
      sensitivity: e.sensitivity,
      protection: p,
    );
