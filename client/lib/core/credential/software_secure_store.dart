/// S 软件档凭证存储（ADR-012 §2.8）。
///
/// 内存持有解密后的条目（守 sync [SecureStore] 契约），落盘为 AEAD 密文整库；
/// **DEK 明文与密文并存**于 [BlobStore]（无硬件保护，≈明文——§2.8 已知弱化，
/// 经用户 5 秒警示知情同意后启用）。所有条目登记 `protection: software`。
///
/// 🔒 红线 #1 承重路径。AI 起草、经人工 + 安全清单审阅接受（2026-07-09）；后续改动仍须
/// 人工 + 安全清单审，不得 AI 独自闭环（AGENTS.md §1）。设计要点（已评审）：① sync put
/// 后异步持久化的写序/durability（内部串行队列，durability 到 [flush] 才保证）；② 明文
/// DEK 落盘是 §2.8 知情同意的 S 档语义；③ 整库重写靠 [FileBlobStore] 临时文件 rename 保原子。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'aead.dart';
import 'blob_store.dart';
import 'secure_store.dart';
import 'types.dart';

const String _dekBlob = 'store.dek'; // S 档：明文 DEK（≈明文）
const String _storeBlob = 'store.enc'; // AEAD 密文的整库

class SoftwareSecureStore implements SecureStore {
  SoftwareSecureStore._(this._aead, this._blobs);

  final Aead _aead;
  final BlobStore _blobs;
  final Map<String, CredentialEntry> _entries = {};

  /// 串行持久化队列：保证多次 put/delete 的写序，不并发覆写。
  Future<void> _persistChain = Future<void>.value();

  /// 构建 S 档 store：读取 / 生成明文 DEK，加载并解密整库。
  static Future<SoftwareSecureStore> open(BlobStore blobs) async {
    final dek = await _loadOrCreateDek(blobs);
    final store = SoftwareSecureStore._(Aes256GcmAead(dek), blobs);
    await store._load();
    return store;
  }

  static Future<List<int>> _loadOrCreateDek(BlobStore blobs) async {
    final existing = await blobs.read(_dekBlob);
    if (existing != null && existing.length == 32) return existing;
    // 每安装随机生成（非内嵌，不变量 ⑦）；S 档下明文落盘。
    final rnd = Random.secure();
    final dek =
        Uint8List.fromList(List<int>.generate(32, (_) => rnd.nextInt(256)));
    await blobs.write(_dekBlob, dek);
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

  /// durability 屏障：等待所有已排队的持久化落盘。收割后调用以确保不丢。
  Future<void> flush() => _persistChain;

  @override
  void put(CredentialEntry entry) {
    _entries[entry.ref] =
        _withProtection(entry, CredentialProtection.software);
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

// ---- 序列化（含 value；仅存在于 AEAD 密文内）----

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
