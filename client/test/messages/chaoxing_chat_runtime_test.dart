import 'dart:convert';
import 'dart:io';

import 'package:elecon/core/credential/secure_store.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/scripts/runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'packaged chat uses real QuickJS HTTP/base64/protobuf bridge and exact cursors',
    () async {
      final package = ScriptPackage.parse(
        File(
          'test/fixtures/community/enhancement-xidian-undergraduate-chaoxing.elecon.json',
        ).readAsStringSync(),
      );
      final credentials = ScriptCredentials(
        store: CredentialStore(store: InMemorySecureStore(releaseMode: false)),
        schoolId: package.manifest.schoolId,
        scriptId: package.manifest.id,
        sdkVersion: 9,
      );
      credentials.set(
        'chaoxing',
        jsonEncode({
          'version': 1,
          'serviceId': 'chaoxing',
          'accountId': '123456',
          'accountLabel': 'Synthetic',
          'cookies': [],
        }),
        namespace: 'xidian.services',
      );
      Future<Map<String, Object?>> fetch(
        String url,
        Map<String, dynamic> init,
      ) async {
        Object body;
        if (url.contains('getUserImToken')) {
          body = {
            'msg': {
              'puid': 123456,
              'uid': 456789,
              'fid': 789012,
              'name': 'Synthetic',
              'hxToken': 'SYNTHETIC_TOKEN',
            },
          };
        } else if (url.endsWith('joined_chatgroups')) {
          body = {
            'data': [
              {'groupid': '789012', 'groupname': 'Synthetic group'},
            ],
          };
        } else if (url.endsWith('contacts/users')) {
          body = {
            'data': ['456780'],
          };
        } else if (url.contains('getUsers4C')) {
          body = {
            'result': 1,
            'data': [
              {'uid': '456780', 'name': 'Synthetic sender'},
            ],
          };
        } else {
          expect(url, endsWith('messageroaming'));
          expect(init['body'], contains('"start":9007199254740995'));
          expect((init['headers'] as Map)['Cookie'], isNull);
          body =
              '{"data":{"is_last":false,"next_key":9007199254740993,"msgs":[{"msg":"CIGAgICAgIAQEggSBjQ1Njc4MBoIEgY3ODkwMTIggKDxwrE0KAIyGQgCIhUIABIRU3ludGhldGljIGhpc3Rvcnk="}]}}';
        }
        return {
          'status': 200,
          'url': url,
          'headers': <String, List<String>>{},
          'body': body is String ? body : jsonEncode(body),
        };
      }

      final conversations =
          await const TrustedScriptRuntime().run(
                package: package,
                capability: 'messages.conversations',
                credentials: credentials,
                params: {'accountId': '123456'},
                fetch: fetch,
              )
              as Map;
      expect((conversations['items'] as List).length, 2);
      final params = {
        'accountId': '123456',
        'conversationId': '789012',
        'conversationKind': 'group',
      };
      final history =
          await const TrustedScriptRuntime().run(
                package: package,
                capability: 'messages.history',
                credentials: credentials,
                params: {...params, 'cursor': '9007199254740995'},
                fetch: fetch,
              )
              as Map;
      expect(history['nextCursor'], '9007199254740993');
      final item = (history['items'] as List).single as Map;
      expect(item['id'], '9007199254740993');
      expect(item['text'], 'Synthetic history');
      expect(item['senderLabel'], 'Synthetic sender');
      var sends = 0, receives = 0, closes = 0;
      final sent =
          await const TrustedScriptRuntime().run(
                package: package,
                capability: 'messages.send',
                credentials: credentials,
                params: {
                  ...params,
                  'clientId': '123',
                  'text': 'Synthetic outgoing',
                },
                fetch: fetch,
                websocketCall: (method, args) async {
                  if (method == 'send') sends++;
                  if (method == 'close') closes++;
                  if (method == 'receive') {
                    return receives++ == 0
                        ? [64, 3, 74, 4, 66, 2, 8, 0]
                        : [
                            64,
                            0,
                            74,
                            15,
                            10,
                            2,
                            8,
                            0,
                            16,
                            123,
                            24,
                            135,
                            128,
                            128,
                            128,
                            128,
                            128,
                            128,
                            16,
                          ];
                  }
                  return null;
                },
              )
              as Map;
      expect(sent['status'], 'sent');
      expect(sent['messageId'], '9007199254740999');
      expect(sends, 2);
      expect(closes, 1);
    },
  );
}
