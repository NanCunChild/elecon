import 'dart:convert';

import 'package:elecon/core/credential/secure_store.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/scripts/runtime.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:flutter_test/flutter_test.dart';

import 'runtime_test.dart' as fixtures;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const runtime = TrustedScriptRuntime();

  Future<Object?> run(
    String source, {
    int sdk = 17,
    Object? failure,
    void Function()? onFetch,
  }) {
    final store = CredentialStore(
      store: InMemorySecureStore(releaseMode: false),
    );
    return runtime.run(
      package: ScriptPackage.parse(
        jsonEncode({
          'format': 'elecon-script/1',
          'manifest': {
            'sdkVersion': sdk,
            'id': 'school.example',
            'version': '0.1.0',
            'schoolId': 'a',
            'name': 'Example',
            if (sdk >= 11) 'accounts': [],
            'browser': false,
            'network': {
              'origins': ['https://school.example'],
            },
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
      ),
      capability: 'notice.list',
      credentials: ScriptCredentials(
        store: store,
        schoolId: 'a',
        scriptId: sdk >= 2 ? 'school.example' : null,
        sdkVersion: sdk,
      ),
      fetch: (url, init) async {
        onFetch?.call();
        if (failure != null) throw failure;
        return fixtures.response(url, init);
      },
    );
  }

  test(
    'SDK17 runtime namespace and Web types exist during module loading',
    () async {
      final output =
          await run('''
      const headers = new Headers({'X-Test':'yes'});
      const same = elecon;
      export const capabilities = {'notice.list': async ctx => ({
        items: [], sourceSystem: String(same === ctx && Object.isFrozen(elecon)) + ':' + headers.get('x-test')
      })};
    ''')
              as Map;
      expect(output['sourceSystem'], 'true:yes');
    },
  );

  test(
    'legacy SDK does not receive SDK17 globals or business errors',
    () async {
      final output =
          await run('''export const capabilities={'notice.list':async ctx=>({
      items:[],sourceSystem:typeof elecon+':'+typeof ctx.errors
    })};''', sdk: 16)
              as Map;
      expect(output['sourceSystem'], 'undefined:undefined');
    },
  );

  test(
    'host errors are classified by typed code, never exception text',
    () async {
      const source = '''export const capabilities={'notice.list':async ctx=>{
      try { await ctx.fetch('https://school.example'); }
      catch (e) { return {items:[],sourceSystem:e.code+':'+e.category+':'+e.message}; }
      throw new Error('expected failure');
    }};''';
      final typed =
          await run(source, failure: const ScriptRunException('network_denied'))
              as Map;
      expect(typed['sourceSystem'], 'network_denied:permission:network_denied');
      final text =
          await run(
                source,
                failure: StateError(
                  'ScriptRunException(network_denied) SYNTHETIC_SECRET',
                ),
              )
              as Map;
      expect(text['sourceSystem'], 'fetch_failed:internal:fetch_failed');
      final unknown =
          await run(
                source,
                failure: const ScriptRunException('SYNTHETIC_SECRET'),
              )
              as Map;
      expect(unknown['sourceSystem'], 'host_failed:internal:host_failed');
    },
  );

  test(
    'legacy fetch retains terminal classification while SDK17 exposes stable codes',
    () async {
      const source = '''export const capabilities={'notice.list':async ctx=>{
      await ctx.fetch('https://school.example'); return {items:[]};
    }};''';
      for (final sdk in [1, 16, 17]) {
        for (final failure in [
          const ScriptRunException('network_denied'),
          StateError('SYNTHETIC_NATIVE_FAILURE'),
        ]) {
          final expected = sdk < 17
              ? 'adapter_failed'
              : failure is ScriptRunException
              ? 'network_denied'
              : 'fetch_failed';
          await expectLater(
            run(source, sdk: sdk, failure: failure),
            fixtures.fails(expected),
          );
        }
      }
    },
  );

  test(
    'SDK17 pre-abort keeps AbortError for JS and reports cancellation without transport',
    () async {
      var calls = 0;
      const begin =
          '''const controller = new AbortController(); controller.abort();''';
      final caught =
          await run('''export const capabilities={'notice.list':async()=>{
      $begin
      try { await fetch('https://school.example',{signal:controller.signal}); }
      catch(e) { return {items:[],sourceSystem:e.name}; }
      throw new Error('expected cancellation');
    }};''', onFetch: () => calls++)
              as Map;
      expect(caught['sourceSystem'], 'AbortError');
      await expectLater(
        run('''export const capabilities={'notice.list':async()=>{
      $begin
      await fetch('https://school.example',{signal:controller.signal});
      return {items:[]};
    }};''', onFetch: () => calls++),
        fixtures.fails('invocation_cancelled'),
      );
      expect(calls, 0);
    },
  );

  test(
    'arbitrary abort reasons and legacy AbortError names keep generic failure',
    () async {
      var calls = 0;
      await expectLater(
        run('''export const capabilities={'notice.list':async()=>{
      const controller=new AbortController(); controller.abort('SYNTHETIC_REASON');
      await fetch('https://school.example',{signal:controller.signal});
      return {items:[]};
    }};''', onFetch: () => calls++),
        fixtures.fails('adapter_failed'),
      );
      await expectLater(
        run('''export const capabilities={'notice.list':async()=>{
      const error=new Error('Synthetic abort');error.name='AbortError';throw error;
    }};''', sdk: 16),
        fixtures.fails('adapter_failed'),
      );
      expect(calls, 0);
    },
  );

  test('school failures preserve a package-bound diagnostic code', () async {
    await expectLater(
      run('''
      const unavailable = elecon.errors.create('course_unavailable');
      export const capabilities={'notice.list':async()=>{throw unavailable;}};
    '''),
      throwsA(
        isA<ScriptRunException>()
            .having((e) => e.code, 'code', 'script_business_error')
            .having(
              (e) => e.businessCode,
              'businessCode',
              'school.example:course_unavailable',
            ),
      ),
    );
  });

  test(
    'business identifiers cannot include arbitrary text or another package',
    () async {
      for (final code in [
        'bad value',
        'Other',
        'x:y',
        'https://school.example',
        'a' * 65,
      ]) {
        final output =
            await run('''export const capabilities={'notice.list':async()=>{
        try { elecon.errors.create(${jsonEncode(code)}); }
        catch (e) { return {items:[],sourceSystem:e.name}; }
        throw new Error('expected failure');
      }};''')
                as Map;
        expect(output['sourceSystem'], 'TypeError');
      }
      await expectLater(
        run('''export const capabilities={'notice.list':async()=>{
      throw {code:'script_business_error',businessCode:'other.package:course_unavailable'};
    }};'''),
        throwsA(
          isA<ScriptRunException>().having(
            (e) => e.businessCode,
            'businessCode',
            isNull,
          ),
        ),
      );
    },
  );
}
