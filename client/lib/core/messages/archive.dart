/// ADR-061: host-owned SQLite, isolated SQL work and H/S/M protected snapshots.
/// Neither the database nor this store is exposed to school scripts or widgets.
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:elecon_contract/messages_conversations.dart';
import 'package:elecon_contract/messages_history.dart';
import 'package:elecon_contract/output_validator_registry.dart';
import 'package:sqlite3/sqlite3.dart';

import '../credential/store.dart';
import '../credential/types.dart';
import '../scripts/manifest.dart';

class ArchivedMessage {
  const ArchivedMessage(this.id, this.content, this.sentAt);
  factory ArchivedMessage.fromData(Map<String, dynamic> row) => ArchivedMessage(
    row['id'] as String,
    _message(row),
    row['sentAt'] as String?,
  );
  final String id;
  final MessagesHistoryItems? content;
  final String? sentAt;
  bool get recalled => content == null;
}

class MessageArchiveView {
  const MessageArchiveView({
    required this.account,
    this.conversations = const [],
    this.messages = const [],
    this.coverage,
    this.fetchedAt,
    this.hasMoreRemote,
    this.nextCursor,
    this.hasMoreLocal = false,
  });
  final Map<String, dynamic> account;
  final List<MessagesConversationsItems> conversations;
  final List<ArchivedMessage> messages;
  final String? coverage;
  final String? fetchedAt;
  final bool? hasMoreRemote;
  final String? nextCursor;
  final bool hasMoreLocal;
}

class MessageArchiveStore {
  MessageArchiveStore(this.store, {int Function()? now})
    : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);
  final CredentialStore store;
  final int Function() now;
  static const type = 'message-archive';
  static const maxBytes = 4 * 1024 * 1024;
  static const retentionMs = 30 * 24 * 60 * 60 * 1000;
  static const capabilities = {
    'messages.conversations',
    'messages.history',
    'messages.send',
  };

  String _source(String school, String provider) => '$type:$school:$provider:';
  String _prefix(ScriptPackage package) =>
      '${_source(package.manifest.schoolId, package.manifest.id)}${package.digest}:';
  String _scope(ScriptPackage package, Map<String, dynamic> account) =>
      jsonEncode([
        package.manifest.schoolId,
        package.manifest.id,
        package.digest,
        account['serviceId'],
        account['accountId'],
      ]);
  String _databaseRef(ScriptPackage package, Map<String, dynamic> account) =>
      '${_prefix(package)}${sha256.convert(utf8.encode(_scope(package, account)))}';

  CredentialEntry? _entry(String ref) => store
      .list()
      .where(
        (e) =>
            e.ref == ref &&
            e.type == type &&
            e.status == CredentialStatus.active &&
            e.acquiredAt <= now() &&
            now() - e.acquiredAt < retentionMs,
      )
      .firstOrNull;

  Map<String, dynamic>? account(ScriptPackage package) {
    final entry = _entry('${_prefix(package)}account');
    if (entry == null || entry.value.length > 4096) return null;
    try {
      final value = jsonDecode(entry.value);
      if (outputValidatorFor('elecon.messages.session', '1.0')!(value) &&
          value['status'] == 'authenticated' &&
          value['accountId'] is String) {
        return Map<String, dynamic>.unmodifiable(value as Map);
      }
    } catch (_) {
      /* Corrupt local identity grants no access. */
    }
    return null;
  }

  /// Object identity changes on every verified session write or revocation.
  Object? revision(ScriptPackage package) =>
      _entry('${_prefix(package)}account');

  void _put(ScriptPackage package, String ref, String value) => store.put(
    CredentialEntry(
      ref: ref,
      schoolId: package.manifest.schoolId,
      type: type,
      scope: const [],
      value: value,
      acquiredAt: now(),
      expiresAt: null,
      status: CredentialStatus.active,
    ),
  );

  bool clearSource(String school, String provider) {
    final entries = store
        .list()
        .where(
          (e) => e.type == type && e.ref.startsWith(_source(school, provider)),
        )
        .toList();
    for (final entry in entries) {
      store.delete(entry.ref);
    }
    return entries.isNotEmpty;
  }

  void saveAccount(ScriptPackage package, Map<String, dynamic> value) {
    if (!outputValidatorFor('elecon.messages.session', '1.0')!(value)) {
      throw const FormatException('invalid_message_account');
    }
    if (value['status'] == 'authenticated' && value['accountId'] is! String) {
      throw const FormatException('invalid_message_account');
    }
    final previous = account(package);
    if (value['status'] != 'authenticated' ||
        value['accountId'] is! String ||
        previous?['serviceId'] != value['serviceId'] ||
        previous?['accountId'] != value['accountId']) {
      clearSource(package.manifest.schoolId, package.manifest.id);
    }
    if (value['status'] == 'authenticated' && value['accountId'] is String) {
      _put(package, '${_prefix(package)}account', jsonEncode(value));
    }
  }

  /// Semantic checks supplement JSON schema, including cross-field binding.
  bool accepts(
    ScriptPackage package,
    String capability,
    Map<String, dynamic> params,
    Map<String, dynamic> data,
  ) {
    final current = account(package);
    if (current == null ||
        params['accountId'] != current['accountId'] ||
        data['accountId'] != current['accountId'] ||
        data['serviceId'] != current['serviceId'] ||
        outputValidatorFor('elecon.$capability', '1.0')?.call(data) != true) {
      return false;
    }
    if (capability != 'messages.conversations' &&
        (data['conversationId'] != params['conversationId'] ||
            data['conversationKind'] != params['conversationKind'])) {
      return false;
    }
    if (capability == 'messages.history') {
      if (data['hasMore'] != (data['nextCursor'] != null) ||
          (data['nextCursor'] != null &&
              data['nextCursor'] == params['cursor'])) {
        return false;
      }
    }
    if (capability == 'messages.send' &&
        (data['clientId'] != params['clientId'] ||
            (data['status'] == 'sent') != (data['messageId'] != null))) {
      return false;
    }
    return true;
  }

  Uint8List? _bytes(ScriptPackage package, Map<String, dynamic> current) {
    final entry = _entry(_databaseRef(package, current));
    if (entry == null) return null;
    if (entry.value.length > maxBytes * 4 ~/ 3 + 4) {
      throw const FormatException('message_archive_size');
    }
    final bytes = base64Decode(entry.value);
    if (bytes.length > maxBytes) {
      throw const FormatException('message_archive_size');
    }
    return bytes;
  }

  Future<void> merge(
    ScriptPackage package,
    String capability,
    Map<String, dynamic> params,
    Map<String, dynamic> data, {
    required bool Function() isActive,
  }) async {
    if (!accepts(package, capability, params, data)) {
      throw const FormatException('message_identity_mismatch');
    }
    final current = account(package)!;
    final admitted = revision(package);
    final bytes = _bytes(package, current);
    final scope = _scope(package, current);
    final time = now();
    final result = await Isolate.run(
      () => _databaseWork(
        bytes,
        scope,
        time,
        capability: capability,
        params: params,
        data: data,
      ),
    );
    if (!isActive() ||
        !identical(admitted, revision(package)) ||
        !accepts(package, capability, params, data)) {
      return;
    }
    _put(
      package,
      _databaseRef(package, current),
      base64Encode(result['bytes'] as Uint8List),
    );
  }

  Future<MessageArchiveView?> read(
    ScriptPackage package, {
    String? conversationId,
    String? conversationKind,
    int limit = 100,
  }) async {
    if (limit < 1 ||
        limit > 2000 ||
        (conversationId == null) != (conversationKind == null)) {
      throw ArgumentError('invalid_message_page');
    }
    final current = account(package);
    if (current == null) return null;
    final bytes = _bytes(package, current);
    if (bytes == null) return MessageArchiveView(account: current);
    final scope = _scope(package, current);
    final time = now();
    final result = await Isolate.run(
      () => _databaseWork(
        bytes,
        scope,
        time,
        conversationId: conversationId,
        conversationKind: conversationKind,
        limit: limit,
      ),
    );
    final rows = result['conversations'] as List;
    return MessageArchiveView(
      account: current,
      conversations: [
        for (final row in rows)
          MessagesConversationsItems(
            conversationId: row['conversationId'] as String,
            conversationKind: row['conversationKind'] as String,
            title: row['title'] as String,
          ),
      ],
      messages: [
        for (final row in result['messages'] as List)
          ArchivedMessage(
            row['id'] as String,
            row['body'] == null
                ? null
                : _message(
                    Map<String, dynamic>.from(
                      jsonDecode(row['body'] as String) as Map,
                    ),
                  ),
            row['sent_at'] as String?,
          ),
      ],
      coverage: result['coverage'] as String?,
      fetchedAt: result['fetchedAt'] as String?,
      hasMoreRemote: result['hasMore'] as bool?,
      nextCursor: result['nextCursor'] as String?,
      hasMoreLocal: result['hasMoreLocal'] == true,
    );
  }
}

MessagesHistoryItems _message(Map<String, dynamic> row) => MessagesHistoryItems(
  id: row['id'] as String,
  text: row['text'] as String,
  kind: row['kind'] as String,
  direction: row['direction'] as String,
  senderId: row['senderId'] as String?,
  senderLabel: row['senderLabel'] as String?,
  sentAt: row['sentAt'] as String?,
);

/// A new isolate/VFS per transaction: no native handle escapes; no filesystem IO.
Map<String, Object?> _databaseWork(
  Uint8List? bytes,
  String scope,
  int now, {
  String? capability,
  Map<String, dynamic> params = const {},
  Map<String, dynamic> data = const {},
  String? conversationId,
  String? conversationKind,
  int limit = 100,
}) {
  // SQLite's VFS registry is process-wide, whereas its Dart callbacks belong
  // to this isolate. Concurrent reads must never resolve another worker's VFS.
  final random = Random.secure();
  final nonce = List.generate(
    4,
    (_) => random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0'),
  ).join();
  final vfs = InMemoryFileSystem(name: 'elecon-messages-$nonce');
  const path = '/messages.db';
  if (bytes != null) {
    final file = vfs
        .xOpen(Sqlite3Filename(path), SqlFlag.SQLITE_OPEN_CREATE)
        .file;
    file.xWrite(bytes, 0);
    file.xClose();
  }
  sqlite3.registerVirtualFileSystem(vfs);
  Database? db;
  try {
    db = sqlite3.open(path, vfs: vfs.name);
    db.execute('PRAGMA temp_store = MEMORY');
    db.execute('PRAGMA journal_mode = MEMORY');
    db.execute(
      'PRAGMA max_page_count = 4096',
    ); // bounded working space before pruning
    final version = db.select('PRAGMA user_version').single.values.single;
    if (bytes != null && version != 1) {
      throw const FormatException('message_archive_version');
    }
    if (bytes == null) {
      db.execute('''
        CREATE TABLE scope (value TEXT NOT NULL);
        CREATE TABLE conversations (kind TEXT, id TEXT, body TEXT NOT NULL, seen INTEGER NOT NULL,
          PRIMARY KEY(kind,id));
        CREATE TABLE messages (kind TEXT, conversation TEXT, id TEXT, body TEXT, sent_at TEXT,
          seen INTEGER NOT NULL, PRIMARY KEY(kind,conversation,id));
        CREATE INDEX message_order ON messages(kind,conversation,sent_at,id);
        CREATE TABLE recalled (kind TEXT, conversation TEXT, id TEXT, seen INTEGER NOT NULL,
          PRIMARY KEY(kind,conversation,id));
        CREATE TABLE pages (kind TEXT, conversation TEXT, value TEXT NOT NULL, seen INTEGER NOT NULL,
          PRIMARY KEY(kind,conversation));
        PRAGMA user_version = 1;
      ''');
      db.execute('INSERT INTO scope VALUES (?)', [scope]);
    }
    if (db.select('SELECT value FROM scope').single['value'] != scope) {
      throw const FormatException('message_archive_scope');
    }
    final cutoff = now - MessageArchiveStore.retentionMs;
    db.execute('BEGIN');
    for (final table in ['messages', 'recalled', 'pages', 'conversations']) {
      db.execute('DELETE FROM $table WHERE seen < ?', [cutoff]);
    }
    final kind = data['conversationKind'];
    final conversation = data['conversationId'];
    void saveMessage(Map<String, dynamic> row) {
      final recalled = db!.select(
        'SELECT 1 FROM recalled WHERE kind=? AND conversation=? AND id=?',
        [kind, conversation, row['id']],
      ).isNotEmpty;
      db.execute(
        '''INSERT INTO messages VALUES (?,?,?,?,?,?)
        ON CONFLICT(kind,conversation,id) DO UPDATE SET body=excluded.body,
        sent_at=COALESCE(excluded.sent_at,messages.sent_at),seen=excluded.seen''',
        [
          kind,
          conversation,
          row['id'],
          recalled ? null : jsonEncode(row),
          row['sentAt'],
          now,
        ],
      );
    }

    if (capability == 'messages.conversations') {
      if (data['coverage'] == 'complete') {
        db.execute('DELETE FROM conversations');
      }
      for (final row in data['items'] as List) {
        db.execute('INSERT OR REPLACE INTO conversations VALUES (?,?,?,?)', [
          row['conversationKind'],
          row['conversationId'],
          jsonEncode(row),
          now,
        ]);
      }
      db.execute('INSERT OR REPLACE INTO pages VALUES (?,?,?,?)', [
        '',
        '',
        jsonEncode({
          'coverage': data['coverage'],
          'fetchedAt': data['fetchedAt'],
        }),
        now,
      ]);
    } else if (capability == 'messages.history') {
      for (final id in data['recalledIds'] as List) {
        db.execute('INSERT OR REPLACE INTO recalled VALUES (?,?,?,?)', [
          kind,
          conversation,
          id,
          now,
        ]);
        db.execute(
          '''INSERT INTO messages VALUES (?,?,?,NULL,NULL,?)
          ON CONFLICT(kind,conversation,id) DO UPDATE SET body=NULL,seen=excluded.seen''',
          [kind, conversation, id, now],
        );
      }
      for (final row in data['items'] as List) {
        saveMessage(Map<String, dynamic>.from(row as Map));
      }
      db.execute('INSERT OR REPLACE INTO pages VALUES (?,?,?,?)', [
        kind,
        conversation,
        jsonEncode({
          'fetchedAt': data['fetchedAt'],
          'hasMore': data['hasMore'],
          if (data['nextCursor'] != null) 'nextCursor': data['nextCursor'],
        }),
        now,
      ]);
    } else if (capability == 'messages.send' && data['status'] == 'sent') {
      saveMessage({
        'id': data['messageId'],
        'text': params['text'],
        'kind': 'text',
        'direction': 'outgoing',
        if (data['sentAt'] != null) 'sentAt': data['sentAt'],
      });
    }
    for (final table in ['messages', 'recalled', 'conversations', 'pages']) {
      final bound = table == 'messages' || table == 'recalled' ? 2000 : 500;
      db.execute(
        'DELETE FROM $table WHERE rowid IN (SELECT rowid FROM $table ORDER BY seen DESC,rowid DESC LIMIT -1 OFFSET ?)',
        [bound],
      );
    }
    // Leave space for indices and tombstones in the 4 MiB protected image.
    while ((db
                .select(
                  'SELECT COALESCE(SUM(length(CAST(body AS BLOB))),0) AS size FROM messages',
                )
                .single['size']
            as int) >
        2 * 1024 * 1024) {
      db.execute(
        'DELETE FROM messages WHERE rowid IN (SELECT rowid FROM messages ORDER BY seen,rowid LIMIT 100)',
      );
    }
    db.execute('COMMIT');
    if (capability != null) {
      db.execute('VACUUM');
      final output = Uint8List.fromList(vfs.fileData[path]!);
      if (output.length > MessageArchiveStore.maxBytes) {
        throw const FormatException('message_archive_size');
      }
      return {'bytes': output};
    }
    final list = db.select('SELECT body FROM conversations ORDER BY kind,id');
    final page = db.select(
      'SELECT value FROM pages WHERE kind=? AND conversation=?',
      [conversationKind ?? '', conversationId ?? ''],
    );
    final metadata = page.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(page.single['value'] as String) as Map<String, dynamic>;
    final messages = conversationId == null
        ? <Map<String, Object?>>[]
        : db
              .select(
                '''SELECT id,body,sent_at FROM messages WHERE kind=? AND conversation=?
        ORDER BY COALESCE(unixepoch(sent_at,'subsec')*1000,seen) DESC,length(id) DESC,id DESC LIMIT ?''',
                [conversationKind, conversationId, limit + 1],
              )
              .map((r) => Map<String, Object?>.from(r))
              .toList();
    return {
      ...metadata,
      'conversations': [
        for (final row in list) jsonDecode(row['body'] as String),
      ],
      'messages': messages.take(limit).toList().reversed.toList(),
      'hasMoreLocal': messages.length > limit,
    };
  } finally {
    db?.close();
    sqlite3.unregisterVirtualFileSystem(vfs);
  }
}
