import 'package:elecon/core/credential/secure_store.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/messages/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'archive_test.dart' as fixtures;

void main() {
  final package = fixtures.package(conversationsVersion: '1.3');
  late MessageArchiveStore archive;
  setUp(() {
    archive = MessageArchiveStore(
      CredentialStore(store: InMemorySecureStore(releaseMode: false)),
    );
    archive.saveAccount(package, fixtures.account);
  });
  Map<String, dynamic> directory() => {
    'serviceId': fixtures.account['serviceId'],
    'accountId': fixtures.account['accountId'],
    'accountLabel': 'Synthetic',
    'fetchedAt': fixtures.stamp,
    'coverage': 'complete',
    'items': [
      {'conversationId': 'same', 'conversationKind': 'group', 'title': 'First'},
      {
        'conversationId': 'same',
        'conversationKind': 'direct',
        'title': 'Second',
      },
    ],
  };
  final params = {
    'accountId': fixtures.account['accountId'],
    'items': [
      {'conversationId': 'same', 'conversationKind': 'group'},
    ],
  };
  Map<String, dynamic> patch(Map<String, dynamic> fields) => {
    'serviceId': fixtures.account['serviceId'],
    'accountId': fixtures.account['accountId'],
    'fetchedAt': '2026-11-03T08:00:00Z',
    'items': [
      {'conversationId': 'same', 'conversationKind': 'group', ...fields},
    ],
  };
  Future<void> load() => archive.merge(
    package,
    'messages.conversations',
    {'accountId': fixtures.account['accountId']},
    directory(),
    isActive: () => true,
  );
  test(
    'supplement input rejects empty duplicate malformed and extra entities',
    () {
      expect(
        isMessageEnrichmentParams({'accountId': 'a', 'items': []}),
        isFalse,
      );
      expect(
        isMessageEnrichmentParams({
          'accountId': 'a',
          'items': [
            {
              'conversationId': 'id',
              'conversationKind': 'group',
              'extra': true,
            },
          ],
        }),
        isFalse,
      );
      final row = {'conversationId': 'id', 'conversationKind': 'group'};
      expect(
        isMessageEnrichmentParams({
          'accountId': 'a',
          'items': [row, row],
        }),
        isFalse,
      );
      expect(
        isMessageEnrichmentParams({
          'accountId': 'a',
          'items': [
            row,
            {'conversationId': 'id', 'conversationKind': 'direct'},
          ],
        }),
        isTrue,
      );
    },
  );
  test(
    'backend without avatars or ordering keeps source order and unknown metadata',
    () async {
      await load();
      final view = (await archive.read(package))!;
      expect(view.conversations.map((r) => r.title), ['First', 'Second']);
      for (final row in view.conversations) {
        expect(row.avatarImages, isNull);
        expect(row.hasContent, isNull);
        expect(row.lastMessageAt, isNull);
      }
    },
  );
  test(
    'sparse metadata updates exact kind/id and does not refresh directory age or remove peers',
    () async {
      await load();
      final revision = archive.directoryRevision(package);
      await archive.merge(
        package,
        'messages.enrich',
        params,
        patch({'title': 'Updated', 'avatarImages': []}),
        isActive: () => true,
        expectedDirectory: revision,
      );
      final view = (await archive.read(package))!;
      expect(view.conversations.map((r) => r.title), ['Updated', 'Second']);
      expect(view.conversations.first.avatarImages, isEmpty);
      expect(view.fetchedAt, fixtures.stamp);
      expect(view.coverage, 'complete');
      expect(archive.directoryRevision(package), same(revision));
      await archive.merge(
        package,
        'messages.enrich',
        params,
        patch({}),
        isActive: () => true,
        expectedDirectory: revision,
      );
      expect(
        (await archive.read(package))!.conversations.first.title,
        'Updated',
      );
    },
  );
  test(
    'new directory invalidates old metadata even when account and ids match',
    () async {
      await load();
      final old = archive.directoryRevision(package);
      await load();
      await archive.merge(
        package,
        'messages.enrich',
        params,
        patch({'title': 'Late'}),
        isActive: () => true,
        expectedDirectory: old,
      );
      expect((await archive.read(package))!.conversations.first.title, 'First');
    },
  );
  test(
    'unsolicited entities duplicate patches and permission updates are rejected',
    () async {
      await load();
      final foreign = patch({'conversationId': 'stranger', 'title': 'Foreign'});
      expect(
        archive.accepts(package, 'messages.enrich', params, foreign),
        isFalse,
      );
      final duplicate = patch({'title': 'One'});
      duplicate['items'] = [
        ...(duplicate['items'] as List),
        ...(duplicate['items'] as List),
      ];
      expect(
        archive.accepts(package, 'messages.enrich', params, duplicate),
        isFalse,
      );
      expect(
        archive.accepts(
          package,
          'messages.enrich',
          params,
          patch({'sendPermission': 'allowed'}),
        ),
        isFalse,
      );
      expect(
        archive.accepts(
          package,
          'messages.enrich',
          params,
          patch({'lastMessageAt': fixtures.stamp}),
        ),
        isFalse,
      );
    },
  );
  test(
    'empty supplement leaves directory intact and cannot create entities',
    () async {
      await load();
      final data = patch({});
      data['items'] = <Object>[];
      await archive.merge(
        package,
        'messages.enrich',
        params,
        data,
        isActive: () => true,
        expectedDirectory: archive.directoryRevision(package),
      );
      expect((await archive.read(package))!.conversations.length, 2);
    },
  );
}
