import 'dart:convert';

import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/credential/secure_store.dart';
import 'package:elecon/core/credential/software_secure_store.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/credential/types.dart';
import 'package:elecon/core/messages/archive.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:flutter_test/flutter_test.dart';

ScriptPackage package({
  String version = '1.0.0',
  String school = 'synthetic',
  String conversationsVersion = '1.0',
}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 9,
      'id': 'synthetic-messages',
      'version': version,
      'schoolId': school,
      'name': 'Synthetic',
      'network': {'origins': []},
      'browser': false,
      'capabilities': [
        for (final cap in [
          'messages.session',
          ...MessageArchiveStore.capabilities,
        ])
          {
            'id': cap,
            'schema': 'elecon.$cap',
            'schemaVersion': cap == 'messages.conversations'
                ? conversationsVersion
                : '1.0',
          },
      ],
    },
    'source': 'export const capabilities = {};',
  }),
);
const account = {
  'serviceId': 'synthetic-service',
  'serviceName': 'Synthetic',
  'accountId': 'synthetic-account',
  'accountLabel': 'Synthetic account',
  'status': 'authenticated',
};
const target = {
  'accountId': 'synthetic-account',
  'conversationId': 'synthetic-conversation',
  'conversationKind': 'group',
};
const stamp = '2026-11-02T08:00:00.000Z';
Map<String, dynamic> history({
  List<String> ids = const ['9007199254740993'],
  List<String> recalled = const [],
  String? cursor,
  String kind = 'group',
}) => {
  'serviceId': account['serviceId'],
  'accountId': account['accountId'],
  'accountLabel': account['accountLabel'],
  'fetchedAt': stamp,
  'conversationId': target['conversationId'],
  'conversationKind': kind,
  'hasMore': cursor != null,
  'nextCursor': ?cursor,
  'recalledIds': recalled,
  'items': [
    for (final id in ids)
      {
        'id': id,
        'text': 'SYNTHETIC_PRIVATE_TEXT_$id',
        'kind': 'text',
        'direction': 'incoming',
        'sentAt': stamp,
      },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final p = package();
  late CredentialStore credentials;
  late MessageArchiveStore archive;
  var time = DateTime.parse(stamp).millisecondsSinceEpoch;
  setUp(() {
    time = DateTime.parse(stamp).millisecondsSinceEpoch;
    credentials = CredentialStore(
      store: InMemorySecureStore(releaseMode: false),
    );
    archive = MessageArchiveStore(credentials, now: () => time)
      ..saveAccount(p, account);
  });
  Future<void> merge(
    Map<String, dynamic> data, {
    Map<String, dynamic> params = target,
  }) =>
      archive.merge(p, 'messages.history', params, data, isActive: () => true);
  Future<MessageArchiveView?> read({int limit = 100, String kind = 'group'}) =>
      archive.read(
        p,
        conversationId: target['conversationId'],
        conversationKind: kind,
        limit: limit,
      );

  test(
    'SQLite snapshot restores exact ids, merges overlapping pages and paginates locally',
    () async {
      await merge(
        history(
          ids: ['9007199254740993', '9007199254740994'],
          cursor: 'cursor-a',
        ),
      );
      await merge(
        history(ids: ['9007199254740992', '9007199254740993']),
        params: {...target, 'cursor': 'cursor-a'},
      );
      final view = (await read(limit: 2))!;
      expect(view.messages.map((row) => row.id), [
        '9007199254740993',
        '9007199254740994',
      ]);
      expect(view.hasMoreLocal, isTrue);
      expect(view.hasMoreRemote, isFalse);
      expect(view.fetchedAt, stamp);
      final snapshot = credentials.list().firstWhere(
        (e) => e.ref.endsWith('account') == false,
      );
      expect(
        utf8.decode(base64Decode(snapshot.value).take(15).toList()),
        'SQLite format 3',
      );
      final reopened = MessageArchiveStore(credentials, now: () => time);
      expect(
        (await reopened.read(
          p,
          conversationId: target['conversationId'],
          conversationKind: 'group',
        ))!.messages.length,
        3,
      );
    },
  );
  test(
    'known content is first, uses source times, retains names and survives recovery',
    () async {
      final updated = package(conversationsVersion: '1.1');
      archive.saveAccount(updated, account);
      Future<void> directory(List<Map<String, dynamic>> items) => archive.merge(
        updated,
        'messages.conversations',
        {'accountId': account['accountId']},
        {
          'serviceId': account['serviceId'],
          'accountId': account['accountId'],
          'accountLabel': account['accountLabel'],
          'fetchedAt': stamp,
          'coverage': 'complete',
          'items': items,
        },
        isActive: () => true,
      );
      final rows = [
        {
          'conversationId': 'unknown',
          'conversationKind': 'group',
          'title': 'Unknown group',
        },
        {
          'conversationId': 'old',
          'conversationKind': 'group',
          'title': 'Older remote group',
          'hasContent': true,
          'lastMessageAt': '2026-10-30T08:00:00Z',
        },
        {
          'conversationId': target['conversationId'],
          'conversationKind': 'group',
          'title': 'Preserved group name',
        },
        {
          'conversationId': 'recent',
          'conversationKind': 'group',
          'title': 'Recent remote group',
          'hasContent': true,
          'lastMessageAt': '2026-11-02T08:01:00Z',
        },
        {
          'conversationId': target['conversationId'],
          'conversationKind': 'direct',
          'title': 'Different direct conversation',
        },
      ];
      await directory(rows);
      await archive.merge(
        updated,
        'messages.history',
        target,
        history(),
        isActive: () => true,
      );
      await directory([
        for (final row in rows)
          {
            ...row,
            if (row['conversationId'] == target['conversationId'] &&
                row['conversationKind'] == 'group')
              'title': target['conversationId'],
          },
      ]);
      final recovered = (await MessageArchiveStore(
        credentials,
        now: () => time,
      ).read(updated))!;
      expect(recovered.conversations.map((row) => row.conversationId), [
        'recent',
        target['conversationId'],
        'old',
        'unknown',
        target['conversationId'],
      ]);
      expect(recovered.conversations[1].title, 'Preserved group name');
      expect(recovered.conversations[1].hasContent, isTrue);
      expect(recovered.conversations[1].lastMessageAt, stamp);
      expect(recovered.conversations[3].hasContent, isNull);
      expect(recovered.conversations[4].hasContent, isNull);
      final malformed = {
        'serviceId': account['serviceId'],
        'accountId': account['accountId'],
        'accountLabel': account['accountLabel'],
        'fetchedAt': stamp,
        'coverage': 'complete',
        'items': [
          {...rows.first, 'hasContent': 'yes'},
        ],
      };
      expect(
        archive.accepts(updated, 'messages.conversations', {
          'accountId': account['accountId'],
        }, malformed),
        isFalse,
      );
      archive.saveAccount(p, account);
      expect(
        archive.accepts(p, 'messages.conversations', {
          'accountId': account['accountId'],
        }, malformed),
        isTrue,
      );
      await archive.merge(
        p,
        'messages.conversations',
        {'accountId': account['accountId']},
        malformed,
        isActive: () => true,
      );
      expect((await archive.read(p))!.conversations.single.hasContent, isNull);
    },
  );
  test(
    'concurrent SQLite workers keep their in-memory VFS and records separate',
    () async {
      final archives = List.generate(8, (_) {
        final store = CredentialStore(
          store: InMemorySecureStore(releaseMode: false),
        );
        return MessageArchiveStore(store, now: () => time)
          ..saveAccount(p, account);
      });
      await Future.wait([
        for (var i = 0; i < archives.length; i++)
          archives[i].merge(
            p,
            'messages.history',
            target,
            history(ids: ['${i + 1}']),
            isActive: () => true,
          ),
      ]);
      final views = await Future.wait([
        for (final instance in archives)
          instance.read(
            p,
            conversationId: target['conversationId'],
            conversationKind: 'group',
          ),
      ]);
      for (var i = 0; i < views.length; i++) {
        expect(views[i]!.messages.single.id, '${i + 1}');
      }
    },
  );
  test(
    'recall before/after history cannot resurrect text; group/direct ids stay separate',
    () async {
      await merge(history(ids: [], recalled: ['9007199254740993']));
      await merge(history());
      expect((await read())!.messages.single.recalled, isTrue);
      await merge(
        history(kind: 'direct'),
        params: {...target, 'conversationKind': 'direct'},
      );
      expect(
        (await read(kind: 'direct'))!.messages.single.content!.text,
        contains('SYNTHETIC_PRIVATE_TEXT'),
      );
      await merge(history(ids: ['9007199254740994']));
      await merge(history(ids: [], recalled: ['9007199254740994']));
      expect((await read())!.messages.every((row) => row.recalled), isTrue);
    },
  );
  test(
    'account, profile, school, digest and script credential boundaries',
    () async {
      await merge(history());
      expect(await archive.read(package(version: '2.0.0')), isNull);
      expect(await archive.read(package(school: 'other-school')), isNull);
      expect(
        await MessageArchiveStore(
          CredentialStore(store: InMemorySecureStore(releaseMode: false)),
        ).read(p),
        isNull,
      );
      final script = ScriptCredentials(
        store: credentials,
        schoolId: p.manifest.schoolId,
        scriptId: p.manifest.id,
        sdkVersion: 9,
      );
      expect(script.list(), isEmpty);
      archive.saveAccount(p, {...account, 'accountId': 'other-account'});
      expect((await archive.read(p))!.messages, isEmpty);
      archive.saveAccount(p, account);
      expect((await read())!.messages, isEmpty);
    },
  );
  test(
    'identity/cursor inconsistencies and cancelled merges never commit',
    () async {
      expect(
        archive.accepts(p, 'messages.history', target, {
          ...history(),
          'accountId': 'other',
        }),
        isFalse,
      );
      expect(
        archive.accepts(p, 'messages.history', target, {
          ...history(),
          'hasMore': true,
        }),
        isFalse,
      );
      expect(
        archive.accepts(p, 'messages.history', {
          ...target,
          'cursor': 'same',
        }, history(cursor: 'same')),
        isFalse,
      );
      await archive.merge(
        p,
        'messages.history',
        target,
        history(),
        isActive: () => false,
      );
      expect((await read())!.messages, isEmpty);
      expect(credentials.list().length, 1);
    },
  );
  test(
    'retention and clear source remove local access without treating cache as login',
    () async {
      await merge(history());
      time += MessageArchiveStore.retentionMs + 1;
      expect(await read(), isNull);
      archive.saveAccount(p, account);
      expect((await read())!.messages, isEmpty);
      archive.clearSource(p.manifest.schoolId, p.manifest.id);
      expect(credentials.list(), isEmpty);
    },
  );
  test(
    'logout and re-login to the same account reject an already running SQL merge',
    () async {
      final pending = merge(history());
      archive.saveAccount(p, {
        'serviceId': account['serviceId'],
        'serviceName': 'Synthetic',
        'status': 'signedOut',
      });
      archive.saveAccount(p, account);
      await pending;
      expect((await read())!.messages, isEmpty);
    },
  );
  test(
    'concurrent archive instances sharing a store retain both updates',
    () async {
      final other = MessageArchiveStore(credentials, now: () => time);
      await Future.wait([
        merge(history(ids: ['first-page'])),
        other.merge(
          p,
          'messages.history',
          target,
          history(ids: ['second-page']),
          isActive: () => true,
        ),
      ]);
      expect(
        (await read())!.messages.map((row) => row.id),
        unorderedEquals(['first-page', 'second-page']),
      );
    },
  );

  test(
    'queued merges cannot enter a new generation of the same account',
    () async {
      final other = MessageArchiveStore(credentials, now: () => time);
      final first = merge(history(ids: ['old-first']));
      final second = other.merge(
        p,
        'messages.history',
        target,
        history(ids: ['old-second']),
        isActive: () => true,
      );
      archive.clearSource(p.manifest.schoolId, p.manifest.id);
      archive.saveAccount(p, account);
      final current = merge(history(ids: ['current']));
      await Future.wait([first, second, current]);
      expect((await read())!.messages.map((row) => row.id), ['current']);
    },
  );

  test('failed commit does not poison the shared merge queue', () async {
    final backend = _FailOnceArchiveStore();
    credentials = CredentialStore(store: backend);
    archive = MessageArchiveStore(credentials, now: () => time)
      ..saveAccount(p, account);
    final other = MessageArchiveStore(credentials, now: () => time);
    final failed = expectLater(
      merge(history(ids: ['failed'])),
      throwsA(isA<StateError>()),
    );
    final next = other.merge(
      p,
      'messages.history',
      target,
      history(ids: ['next']),
      isActive: () => true,
    );
    await Future.wait([failed, next]);
    expect((await read())!.messages.map((row) => row.id), ['next']);
  });
  test(
    'S protection encrypts SQLite snapshot and restores it after restart',
    () async {
      final blobs = InMemoryBlobStore();
      final backend = await SoftwareSecureStore.open(blobs);
      credentials = CredentialStore(store: backend);
      archive = MessageArchiveStore(credentials, now: () => time)
        ..saveAccount(p, account);
      await merge(history());
      await backend.flush();
      final disk = await blobs.read('store.enc');
      expect(
        utf8.decode(disk!, allowMalformed: true),
        isNot(contains('SYNTHETIC_PRIVATE_TEXT')),
      );
      expect(
        utf8.decode(disk, allowMalformed: true),
        isNot(contains('SQLite format')),
      );
      final restored = MessageArchiveStore(
        CredentialStore(store: await SoftwareSecureStore.open(blobs)),
        now: () => time,
      );
      expect(
        (await restored.read(
          p,
          conversationId: target['conversationId'],
          conversationKind: 'group',
        ))!.messages.single.id,
        '9007199254740993',
      );
    },
  );
  test(
    'bounded archive keeps recent messages within snapshot and count budgets',
    () async {
      for (var page = 0; page < 11; page++) {
        final data = history(
          ids: [for (var i = 0; i < 200; i++) '${10000 + page * 200 + i}'],
        );
        await merge(data);
        time++;
      }
      expect((await read(limit: 2000))!.messages.length, 2000);
      final bytes = credentials
          .list()
          .where((row) => !row.ref.endsWith('account'))
          .single;
      expect(
        base64Decode(bytes.value).length,
        lessThanOrEqualTo(MessageArchiveStore.maxBytes),
      );
    },
  );
  test('byte quota counts UTF-8 and prunes large multilingual pages', () async {
    final data = history(ids: [for (var i = 0; i < 200; i++) '${10000 + i}']);
    for (final row in data['items'] as List) {
      row['text'] = '合成消息' * 1500;
    }
    await merge(data);
    final view = (await read(limit: 2000))!;
    expect(view.messages, isNotEmpty);
    expect(view.messages.length, lessThan(200));
    final record = credentials
        .list()
        .where((e) => !e.ref.endsWith('account'))
        .single;
    expect(
      base64Decode(record.value).length,
      lessThanOrEqualTo(MessageArchiveStore.maxBytes),
    );
  });
}

class _FailOnceArchiveStore extends InMemorySecureStore {
  _FailOnceArchiveStore() : super(releaseMode: false);
  var fail = true;

  @override
  void put(CredentialEntry entry) {
    if (fail &&
        entry.type == MessageArchiveStore.type &&
        !entry.ref.endsWith('account')) {
      fail = false;
      throw StateError('synthetic archive write failure');
    }
    super.put(entry);
  }
}
