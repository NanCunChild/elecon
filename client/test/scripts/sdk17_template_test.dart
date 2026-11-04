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
    'SDK17 author template runs through the real bridge and standard output',
    () async {
      const path = '../adapters/_template/trusted/standard-js';
      final manifest = jsonDecode(
        File('$path/manifest.json').readAsStringSync(),
      );
      final package = ScriptPackage.parse(
        jsonEncode({
          'format': 'elecon-script/1',
          'manifest': manifest,
          'source': File('$path/index.js').readAsStringSync(),
        }),
      );
      final credentials = ScriptCredentials(
        store: CredentialStore(store: InMemorySecureStore(releaseMode: false)),
        schoolId: 'example',
        scriptId: package.manifest.id,
        sdkVersion: 17,
      );
      for (final status in [200, 503]) {
        final run = const TrustedScriptRuntime().run(
          package: package,
          capability: 'notice.list',
          credentials: credentials,
          fetch: (url, init) async {
            expect(url, 'https://school.example/notices');
            expect(init['headers'], {'accept': 'application/json'});
            return {
              'status': status,
              'url': url,
              'headers': <String, List<String>>{},
              'bodyBytes': utf8.encode('{"items":[{"id":7,"title":"合成通知"}]}'),
            };
          },
        );
        if (status == 200) {
          expect(await run, {
            'items': [
              {
                'id': '7',
                'title': '合成通知',
                'source': 'Campus',
                'category': 'unknown',
              },
            ],
          });
        } else {
          await expectLater(
            run,
            throwsA(
              isA<ScriptRunException>()
                  .having((e) => e.code, 'code', 'script_business_error')
                  .having(
                    (e) => e.businessCode,
                    'businessCode',
                    'standard-js-example:notices_unavailable',
                  ),
            ),
          );
        }
      }
    },
  );
}
