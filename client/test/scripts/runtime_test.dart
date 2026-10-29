import 'dart:async';
import 'dart:convert';
import 'package:elecon/core/credential/secure_store.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/scripts/runtime.dart';
import 'package:flutter_test/flutter_test.dart';

ScriptPackage script(String source, {bool browser = false}) =>
    ScriptPackage.parse(
      jsonEncode({
        'format': 'elecon-script/1',
        'manifest': {
          'sdkVersion': 1,
          'id': 'school.example',
          'version': '0.1.0',
          'schoolId': 'a',
          'name': 'Example',
          'network': {
            'origins': ['https://school.example'],
          },
          'browser': browser,
          'capabilities': [
            {
              'id': 'notice.list',
              'schema': 'elecon.notice.list',
              'schemaVersion': '1.1',
            },
          ],
        },
        'source': source,
      }),
    );
Matcher fails(String code) =>
    throwsA(isA<ScriptRunException>().having((e) => e.code, 'code', code));
Future<Map<String, Object?>> response(
  String url,
  Map<String, dynamic> init,
) async => {
  'status': 200,
  'url': url,
  'headers': <String, List<String>>{},
  'body': '{"items":[]}',
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const runtime = TrustedScriptRuntime();
  late CredentialStore store;
  late ScriptCredentials credentials;
  setUp(() {
    store = CredentialStore(store: InMemorySecureStore(releaseMode: false));
    credentials = ScriptCredentials(store: store, schoolId: 'a');
  });
  test(
    'real QuickJS reads secret and sees raw multi-value Set-Cookie',
    () async {
      credentials.set('cas', 'SYNTHETIC_CAS');
      final seen = <Map<String, dynamic>>[];
      final output = await runtime.run(
        package: script('''
      export const capabilities={'notice.list':async(ctx)=>{
        const missing=await ctx.credentials.get('missing');
        if(missing !== null)throw new Error('missing must be null');
        const c=await ctx.credentials.get('cas');
        if(c.expiresAt !== null)throw new Error('expiry must be null');
        const r=await ctx.fetch('https://school.example/api',{headers:{Cookie:c.value}});
        await ctx.credentials.set('session',r.headers.getSetCookie()[1]);
        return {items:[],sourceSystem:r.headers.get('X-System')};
      }};
    '''),
        capability: 'notice.list',
        credentials: credentials,
        fetch: (url, init) async {
          seen.add(init);
          return {
            'status': 200,
            'url': url,
            'headers': {
              'Set-Cookie': ['a=ONE', 'b=TWO'],
              'X-System': ['demo'],
            },
            'body': '',
          };
        },
      );
      expect(output, {'items': [], 'sourceSystem': 'demo'});
      expect(seen.single['headers'], {'Cookie': 'SYNTHETIC_CAS'});
      expect(credentials.get('session')!['value'], 'b=TWO');
    },
  );
  test(
    'JS and asynchronous host calls keep UI event loop responsive',
    () async {
      var ticks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 5),
        (_) => ticks++,
      );
      try {
        await runtime.run(
          package: script('''
      export const capabilities={'notice.list':async(ctx)=>{
        const stop=Date.now()+150;while(Date.now()<stop){}
        return {items:[]};
      }};
    '''),
          capability: 'notice.list',
          credentials: credentials,
          fetch: (u, i) async {
            await Future<void>.delayed(const Duration(milliseconds: 30));
            return response(u, i);
          },
        );
      } finally {
        timer.cancel();
      }
      expect(ticks, greaterThan(3));
    },
  );
  test(
    'raw legacy-encoded bytes survive QuickJS while text reports unsupported encoding',
    () async {
      final output = await runtime.run(
        package: script('''
      export const capabilities={'notice.list':async(ctx)=>{
        const r=await ctx.fetch('https://school.example/legacy');
        const bytes=await r.bytes();const buffer=await r.arrayBuffer();
        let reason='';try{await r.text();}catch(e){reason=e.message;}
        return {items:[],sourceSystem:[bytes[0],bytes[1],new Uint8Array(buffer)[0],reason].join(',')};
      }};
    '''),
        capability: 'notice.list',
        credentials: credentials,
        fetch: (url, init) async => {
          'status': 200,
          'url': url,
          'headers': {},
          'body': null,
          'bodyBytes': [0xc4, 0xe3, 0xba, 0xc3],
        },
      );
      expect(
        (output as Map)['sourceSystem'],
        '196,227,196,unsupported_encoding',
      );
    },
  );
  test('manifest outside fetch is rejected before transport', () async {
    var calls = 0;
    await runtime.run(
      package: script('''
      export const capabilities={'notice.list':async(ctx)=>{
        try{await ctx.fetch('https://foreign.example/');}catch(e){}return {items:[]};
      }};
    '''),
      capability: 'notice.list',
      credentials: credentials,
      fetch: (u, i) async {
        calls++;
        return response(u, i);
      },
    );
    expect(calls, 0);
  });
  test(
    'DOM callback source and arguments are forwarded only with permission',
    () async {
      final calls = <String>[];
      final output = await runtime.run(
        package: script('''
      export const capabilities={'notice.list':async(ctx)=>{
        await ctx.browser.open('https://school.example/login');
        const title=await ctx.browser.evaluate((n)=>document.title+n,'!');
        await ctx.browser.cookies();
        if(await ctx.browser.text('#missing') !== null)throw new Error('DOM null lost');
        return {items:[],sourceSystem:title};
      }};
    ''', browser: true),
        capability: 'notice.list',
        credentials: credentials,
        fetch: response,
        browserCall: (method, args) async {
          calls.add(method);
          if (method == 'evaluate') {
            expect(args['source'], contains('document.title'));
            return 'Example!';
          }
          return null;
        },
      );
      expect(calls, ['open', 'evaluate', 'cookies', 'text']);
      expect((output as Map)['sourceSystem'], 'Example!');
      final noBrowser = await runtime.run(
        package: script('''
      export const capabilities={'notice.list':async(ctx)=>({items:[],sourceSystem:typeof ctx.browser})};
    '''),
        capability: 'notice.list',
        credentials: credentials,
        fetch: response,
      );
      expect((noBrowser as Map)['sourceSystem'], 'undefined');
    },
  );
  test(
    'browser cookie values are known secrets before script logs them',
    () async {
      final logs = <String>[];
      await runtime.run(
        package: script('''
      export const capabilities={'notice.list':async(ctx)=>{
        const cookies=await ctx.browser.cookies();
        ctx.log('info',cookies[0].value); return {items:[]};
      }};
    ''', browser: true),
        capability: 'notice.list',
        credentials: credentials,
        fetch: response,
        browserCall: (method, args) async => [
          {'name': 'SESSION', 'value': 'SYNTHETIC_BROWSER_COOKIE'},
        ],
        onLog: (level, message) => logs.add(message),
      );
      expect(logs.single, '[credential]');
    },
  );
  test(
    'cookie restoration forwards URL and values and sanitizes later logs',
    () async {
      final logs = <String>[];
      final output = await runtime.run(
        package: script('''
      export const capabilities={'notice.list':async(ctx)=>{
        const result=await ctx.browser.setCookies('https://school.example/',[
          {name:'SESSION',value:'SYNTHETIC_RESTORED_COOKIE',path:'/'}
        ]);
        if(result !== undefined)throw new Error('setCookies must resolve void');
        ctx.log('info','restored SYNTHETIC_RESTORED_COOKIE');
        return {items:[]};
      }};
    ''', browser: true),
        capability: 'notice.list',
        credentials: credentials,
        fetch: response,
        browserCall: (method, args) async {
          expect(method, 'setCookies');
          expect(args['url'], 'https://school.example/');
          expect(args['cookies'], [
            {
              'name': 'SESSION',
              'value': 'SYNTHETIC_RESTORED_COOKIE',
              'path': '/',
            },
          ]);
          return null;
        },
        onLog: (level, message) => logs.add(message),
      );
      expect(output, {'items': []});
      expect(logs.single, 'restored [credential]');
    },
  );
  test('malformed schema and non-JSON output are rejected', () async {
    await expectLater(
      runtime.run(
        package: script('''
      export const capabilities={'notice.list':async()=>({items:[{title:'missing'}]})};
    '''),
        capability: 'notice.list',
        credentials: credentials,
        fetch: response,
      ),
      fails('schema_validation_failed'),
    );
    for (final expression in [
      '({items:[],bad:undefined})',
      '({items:[],bad:NaN})',
      '({items:[],bad:1n})',
      'new Date()',
      '(()=>{const a={items:[]};a.a=a;return a;})()',
    ]) {
      await expectLater(
        runtime.run(
          package: script(
            'export const capabilities={"notice.list":async()=>($expression)};',
          ),
          capability: 'notice.list',
          credentials: credentials,
          fetch: response,
        ),
        fails('non_json_output'),
      );
    }
  });
  test(
    'identity invalidation cancels unresolved fetch and blocks late writes',
    () async {
      var active = true;
      final entered = Completer<void>();
      final result = Completer<Map<String, Object?>>();
      final future = runtime.run(
        package: script('''
      export const capabilities={'notice.list':async(ctx)=>{
        await ctx.fetch('https://school.example/api');await ctx.credentials.set('late','LATE');return {items:[]};
      }};
    '''),
        capability: 'notice.list',
        credentials: credentials,
        isActive: () => active,
        fetch: (u, i) {
          entered.complete();
          return result.future;
        },
      );
      final assertion = expectLater(future, fails('invocation_cancelled'));
      await entered.future;
      active = false;
      await assertion;
      result.complete(await response('https://school.example/api', {}));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(store.list(), isEmpty);
    },
  );
  test(
    'unresolved JS promises have a wall deadline; loops are interrupted',
    () async {
      await expectLater(
        runtime.run(
          package: script('''
      export const capabilities={'notice.list':async()=>await new Promise(()=>{})};
    '''),
          capability: 'notice.list',
          credentials: credentials,
          fetch: response,
          wallTimeout: const Duration(milliseconds: 100),
        ),
        fails('wall_timeout'),
      );
      await expectLater(
        runtime.run(
          package: script('''
      export const capabilities={'notice.list':async()=>{while(true){}}};
    '''),
          capability: 'notice.list',
          credentials: credentials,
          fetch: response,
          cpuTimeoutMs: 100,
        ),
        throwsA(isA<ScriptRunException>()),
      );
    },
  );
  test('request budget remains fatal when JS catches the rejection', () async {
    await expectLater(
      runtime.run(
        package: script('''
      export const capabilities={'notice.list':async(ctx)=>{
        for(let i=0;i<3;i++)try{await ctx.fetch('https://school.example/api');}catch(e){}
        return {items:[]};
      }};
    '''),
        capability: 'notice.list',
        credentials: credentials,
        fetch: response,
        maxRequests: 1,
      ),
      fails('request_limit'),
    );
  });
  test(
    'known secrets and URLs are redacted and source error text is hidden',
    () async {
      credentials.set('secret', 'SYNTHETIC_SECRET');
      final logs = <String>[];
      await runtime.run(
        package: script('''
      console.log('SYNTHETIC_SECRET');
      export const capabilities={'notice.list':async(ctx)=>{
        const c=await ctx.credentials.get('secret');
        await ctx.credentials.delete('secret');
        ctx.log('info',c.value+' https://school.example/?token='+c.value);
        return {items:[]};
      }};
    '''),
        capability: 'notice.list',
        credentials: credentials,
        fetch: response,
        onLog: (l, m) => logs.add(m),
      );
      expect(logs, hasLength(2));
      expect(logs.every((line) => !line.contains('SYNTHETIC_SECRET')), isTrue);
      credentials.set('secret', 'SYNTHETIC_SECRET');
      final errors = <String>[];
      await expectLater(
        runtime.run(
          package: script('''
      export const capabilities={'notice.list':async()=>{throw new Error('Request failed SYNTHETIC_SECRET https://school.example/?token=SYNTHETIC_SECRET');}};
    '''),
          capability: 'notice.list',
          credentials: credentials,
          fetch: response,
          onLog: (level, message) {
            expect(level, 'error');
            errors.add(message);
          },
        ),
        fails('adapter_failed'),
      );
      expect(errors.single, contains('Request failed'));
      expect(errors.single, isNot(contains('SYNTHETIC_SECRET')));
      expect(errors.single, isNot(contains('https://')));
      expect(errors.single.length, lessThanOrEqualTo(4096));
    },
  );
}
