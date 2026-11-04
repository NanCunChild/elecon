import 'dart:convert';

import 'package:elecon/core/credential/secure_store.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/scripts/runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<dynamic> run(
    String body, {
    int sdk = 17,
    String prefix = '',
    Future<Map<String, Object?>> Function(String, Map<String, dynamic>)? fetch,
  }) async {
    final package = ScriptPackage.parse(
      jsonEncode({
        'format': 'elecon-script/1',
        'manifest': {
          'sdkVersion': sdk,
          'id': 'school.example',
          'version': '0.1.0',
          'schoolId': 'a',
          'name': 'Example',
          'network': {
            'origins': ['https://school.example'],
          },
          'browser': false,
          'accounts': [],
          'capabilities': [
            {
              'id': 'notice.list',
              'schema': 'elecon.notice.list',
              'schemaVersion': '1.1',
            },
          ],
        },
        'source':
            '''$prefix
export const capabilities = {'notice.list': async ctx => {
 const result = await (async () => {$body})();
 return {items:[], sourceSystem:JSON.stringify(result)};
}};''',
      }),
    );
    final output =
        await const TrustedScriptRuntime().run(
              package: package,
              capability: 'notice.list',
              credentials: ScriptCredentials(
                store: CredentialStore(
                  store: InMemorySecureStore(releaseMode: false),
                ),
                schoolId: 'a',
                scriptId: 'school.example',
                sdkVersion: sdk,
              ),
              fetch:
                  fetch ??
                  (url, init) async => {
                    'status': 200,
                    'url': url,
                    'headers': <String, List<String>>{
                      'content-type': ['application/json'],
                    },
                    'body': '{"message":"校园 😀"}',
                    'bodyBytes': utf8.encode('{"message":"校园 😀"}'),
                  },
            )
            as Map;
    return jsonDecode(output['sourceSystem'] as String);
  }

  test(
    'SDK17 globals exist at module load; old SDK remains unchanged',
    () async {
      expect(
        await run('return initial;', prefix: 'const initial = typeof Headers;'),
        'function',
      );
      expect(await run('return [typeof Headers,typeof fetch];', sdk: 16), [
        'undefined',
        'undefined',
      ]);
    },
  );

  test(
    'standard request and response preserve UTF8 and header semantics',
    () async {
      Map<String, dynamic>? sent;
      final output = await run(
        r'''
const headers = new Headers([['X-Test','one'], ['x-test','two']]);
const request = new Request('https://school.example/data', {
  method:'post',headers,body:'校园 😀'
});
const response = await fetch(request);
const duplicate = response.clone();
const result = await response.json();
let consumed = false;
try { await response.text(); } catch (error) { consumed = error instanceof TypeError; }
let immutable = false;
try { response.headers.set('x','y'); } catch (error) { immutable = error instanceof TypeError; }
return {result, consumed, immutable, bodyUsed:response.bodyUsed,
 copy:await duplicate.text(),requestUsed:request.bodyUsed,ok:response.ok,
 cookies:response.headers.getSetCookie()};
''',
        fetch: (url, init) async {
          sent = init;
          return {
            'status': 200,
            'url': url,
            'headers': <String, List<String>>{
              'set-cookie': ['a=1', 'b=2'],
            },
            'bodyBytes': utf8.encode('{"message":"校园 😀"}'),
            'body': '{"message":"校园 😀"}',
          };
        },
      );
      expect(sent!['method'], 'POST');
      expect(sent!['headers'], containsPair('x-test', 'one, two'));
      expect(
        sent!['headers'],
        containsPair('content-type', 'text/plain;charset=UTF-8'),
      );
      expect(sent!['body'], utf8.encode('校园 😀'));
      expect(output, {
        'result': {'message': '校园 😀'},
        'consumed': true,
        'immutable': true,
        'bodyUsed': true,
        'copy': '{"message":"校园 😀"}',
        'requestUsed': true,
        'ok': true,
        'cookies': ['a=1', 'b=2'],
      });
    },
  );

  test(
    'constructor bodies copy bytes and handle UTF8 replacement and BOM',
    () async {
      expect(
        await run(r'''
const bytes = new Uint8Array([0xef,0xbb,0xbf,0xe6,0xa0,0xa1,0xc0,0xaf]);
const response = new Response(bytes);
bytes.fill(65);
const encoded = await new Response('x\ud800y😀').bytes();
return [await response.text(), Array.from(encoded), await Response.json({x:1}).json()];
'''),
        [
          '校��',
          [120, 239, 191, 189, 121, 240, 159, 152, 128],
          {'x': 1},
        ],
      );
    },
  );

  test(
    'Headers iterable forms retain separate cookies and reject injection',
    () async {
      expect(
        await run(r'''
const headers = new Headers([['Z','last'],['A',' first '],['Set-Cookie','x=1'],['Set-Cookie','y=2']]);
const copied = new Headers(headers); headers.delete('a');
let rejected = 0;
for (const [name,value] of [['Bad Name','x'],['X','x\r\ny'],['X','校园']]) {
 try { copied.set(name,value); } catch (error) { if(error instanceof TypeError) rejected++; }
}
return {entries:[...copied],rejected};
'''),
        {
          'entries': [
            ['a', 'first'],
            ['set-cookie', 'x=1'],
            ['set-cookie', 'y=2'],
            ['z', 'last'],
          ],
          'rejected': 3,
        },
      );
    },
  );

  test(
    'unsupported options and invalid methods fail before transport',
    () async {
      var calls = 0;
      expect(
        await run(
          r'''
let rejected = 0;
for (const init of [{cache:'no-store'},{credentials:'include'},{method:'TRACE'},{method:'GET',body:'x'}]) {
 try { await fetch('https://school.example',init); }
 catch(error) { if(error instanceof TypeError) rejected++; }
}
return rejected;
''',
          fetch: (_, _) async {
            calls++;
            throw StateError('must not run');
          },
        ),
        4,
      );
      expect(calls, 0);
    },
  );

  test(
    'pre-aborted fetch never calls host and preserves abort reason',
    () async {
      var calls = 0;
      expect(
        await run(
          r'''
const controller = new AbortController(); controller.abort('stop');
try { await fetch('https://school.example',{signal:controller.signal}); }
catch(error) { return [error,controller.signal.aborted,controller.signal.reason]; }
''',
          fetch: (_, _) async {
            calls++;
            throw StateError('must not run');
          },
        ),
        ['stop', true, 'stop'],
      );
      expect(calls, 0);
    },
  );

  test(
    'abort rejects promptly and discards a completed native request',
    () async {
      var calls = 0;
      expect(
        await run(
          r'''
const controller = new AbortController(); let resolved = false, name;
const pending = fetch('https://school.example',{signal:controller.signal})
 .then(() => { resolved = true; }, error => { name = error.name; });
setTimeout(() => controller.abort(),5);
await pending;
await new Promise(resolve => setTimeout(resolve,60));
return [resolved,name];
''',
          fetch: (url, _) async {
            calls++;
            await Future<void>.delayed(const Duration(milliseconds: 25));
            return {
              'status': 200,
              'url': url,
              'headers': <String, List<String>>{},
              'bodyBytes': [65],
              'body': 'A',
            };
          },
        ),
        [false, 'AbortError'],
      );
      expect(calls, 1);
    },
  );

  test(
    'abort after response prevents body reads and listener fires once',
    () async {
      expect(
        await run(r'''
const controller = new AbortController(); let calls = 0;
controller.signal.addEventListener('abort',() => calls++,{once:true});
const response = await fetch('https://school.example',{signal:controller.signal});
controller.abort('closed'); controller.abort('again');
try { await response.text(); } catch(error) { return [error,calls]; }
'''),
        ['closed', 1],
      );
    },
  );

  test(
    'Headers iteration observes deletions, insertions and updated values',
    () async {
      expect(
        await run(r'''
const deleted = new Headers({a:'1',b:'2',c:'3'}), deletedSeen = [];
for (const [key,value] of deleted) {
  deletedSeen.push([key,value]);
  if (key === 'a') deleted.delete('b');
}
const appended = new Headers({a:'1',c:'3'}), appendedSeen = [];
for (const [key,value] of appended) {
  appendedSeen.push([key,value]);
  if (key === 'a') { appended.set('b','2'); appended.append('c','4'); }
}
const current = new Headers({a:'1',b:'2',c:'3'}), currentSeen = [];
current.forEach((value,key) => {
  currentSeen.push(key);
  if (key === 'a') current.delete('a');
});
return {deleted:deletedSeen,appended:appendedSeen,current:currentSeen};
'''),
        {
          'deleted': [
            ['a', '1'],
            ['c', '3'],
          ],
          'appended': [
            ['a', '1'],
            ['b', '2'],
            ['c', '3, 4'],
          ],
          'current': ['a', 'c'],
        },
      );
    },
  );

  test(
    'request clone does not consume original; null bodies stay unused',
    () async {
      expect(
        await run(r'''
const request = new Request('https://school.example',{method:'POST',body:'x'});
const copy = request.clone(); const before = request.bodyUsed;
const copied = await copy.text(); const original = await request.text();
const empty = new Response(null,{status:204}); await empty.text();
return [before,copied,original,empty.bodyUsed];
'''),
        [false, 'x', 'x', false],
      );
    },
  );
}
