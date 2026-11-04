import 'dart:async';
import 'dart:convert';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/scripts/data_cache.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/scripts/runtime.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

ScriptPackage localized({
  int sdk = 13,
  bool resources = true,
  String? source,
}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': sdk,
      'id': 'synthetic.locale',
      'schoolId': 'synthetic',
      'version': '1.0.0',
      'name': 'Synthetic',
      'browser': false,
      'network': {'origins': []},
      'accounts': [],
      'capabilities': [
        {
          'id': 'notice.list',
          'schema': 'elecon.notice.list',
          'schemaVersion': '1.1',
        },
      ],
      'home': [
        {'capability': 'notice.list', 'ttlSeconds': 30, 'preload': false},
      ],
      if (resources)
        'localization': {
          'defaultLocale': 'en',
          'messages': {
            'en': {
              'greeting': 'Hello {name}',
              'fallback': 'Default',
              'quoted': '"</script>\\text',
            },
            'ru': {'greeting': 'Привет, {name}'},
            'uz-Cyrl': {'greeting': 'Салом {name}'},
            'fa': {'greeting': 'سلام {name}'},
          },
        },
    },
    'source':
        source ??
        '''export const capabilities={'notice.list':async ctx=>({items:[],
 sourceSystem:ctx.locale+'|'+ctx.i18n.locale+'|'+ctx.i18n.t('greeting',{name:'Ada'})+'|'+ctx.i18n.t('fallback')})};''',
  }),
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<Map> run(ScriptPackage p, String locale) async =>
      await const TrustedScriptRuntime().run(
            package: p,
            capability: 'notice.list',
            locale: locale,
            credentials: ScriptCredentials(
              store: CredentialStore(),
              schoolId: 'synthetic',
              scriptId: p.manifest.id,
              sdkVersion: p.manifest.sdkVersion,
            ),
            fetch: (_, _) async => throw StateError('no traffic'),
          )
          as Map;
  test(
    'real QuickJS resolves language/script/region fallback and default missing keys',
    () async {
      final p = localized();
      for (final (locale, value) in [
        ('ru_RU', 'ru-RU|ru|Привет, Ada|Default'),
        ('uz-Cyrl-UZ', 'uz-Cyrl-UZ|uz-Cyrl|Салом Ada|Default'),
        ('fa-IR', 'fa-IR|fa|سلام Ada|Default'),
        ('uz-Latn', 'uz-Latn|en|Hello Ada|Default'),
        ('tr', 'tr|en|Hello Ada|Default'),
      ]) {
        expect((await run(p, locale))['sourceSystem'], value);
      }
    },
  );
  test(
    'literal substitution rejects unknown keys, getters, extra and nonfinite parameters',
    () async {
      final p = localized(
        source: r'''export const capabilities={'notice.list':async ctx=>{
   const failures=[];
   for(const call of [()=>ctx.i18n.t('toString'),()=>ctx.i18n.t('greeting'),()=>ctx.i18n.t('greeting',{name:'a',extra:1}),
    ()=>ctx.i18n.t('greeting',{name:NaN}),()=>ctx.i18n.t('greeting',{get name(){throw new Error('getter');}}),
    ()=>ctx.i18n.t('greeting',Object.defineProperty({name:'a'},'extra',{value:1}))]){
    try{call();failures.push('unexpected')}catch(e){failures.push(e.code)}
   }
   if(!Object.isFrozen(ctx.i18n)||!Object.isFrozen(ctx.i18n.supportedLocales))throw new Error('mutable');
   return {items:[],sourceSystem:JSON.stringify([ctx.i18n.t('greeting',{name:'$& {name}'}),ctx.i18n.t('quoted'),failures])};
  }};''',
      );
      final result =
          jsonDecode((await run(p, 'en'))['sourceSystem'] as String) as List;
      expect(result[0], r'Hello $& {name}');
      expect(result[1], '"</script>\\text');
      expect(result[2], [
        'localization_invalid_key',
        ...List.filled(5, 'localization_invalid_arguments'),
      ]);
    },
  );
  test('SDK13 locale without dictionaries and unchanged SDK12 surface', () async {
    for (final sdk in [12, 13]) {
      final p = localized(
        sdk: sdk,
        resources: false,
        source:
            "export const capabilities={'notice.list':async ctx=>({items:[],sourceSystem:typeof ctx.locale+'|'+typeof ctx.i18n})};",
      );
      expect(
        (await run(p, 'fa'))['sourceSystem'],
        sdk == 13 ? 'string|undefined' : 'undefined|undefined',
      );
    }
  });
  test(
    'cache locale isolation preserves both languages and timestamps, old SDK is unchanged',
    () {
      var now = 1000000;
      final store = CredentialStore();
      final p = localized();
      final en = ScriptDataCache(store, locale: 'en', now: () => now),
          fa = ScriptDataCache(store, locale: 'fa', now: () => now);
      en.write(p, 'notice.list', {}, {'items': [], 'sourceSystem': 'English'});
      expect(fa.latest(p, 'notice.list'), isNull);
      now += 1000;
      fa.write(p, 'notice.list', {}, {'items': [], 'sourceSystem': 'فارسی'});
      expect(
        (en.latest(p, 'notice.list')!.data as Map)['sourceSystem'],
        'English',
      );
      expect((fa.read(p, 'notice.list')!.data as Map)['sourceSystem'], 'فارسی');
      expect(
        en.latest(p, 'notice.list')!.fetchedAt.millisecondsSinceEpoch,
        1000000,
      );
      final old = localized(sdk: 12, resources: false);
      en.write(old, 'notice.list', {}, {'items': []});
      expect(fa.read(old, 'notice.list'), isNotNull);
    },
  );
  test(
    'locale switch cancels old output and does not cache or replay it',
    () async {
      final p = localized(
        source:
            "export const capabilities={'notice.list':async ctx=>{ctx.log('info','locale_ready');await new Promise(r=>setTimeout(r,100));return {items:[],sourceSystem:ctx.locale}}};",
      );
      final session = SessionController();
      addTearDown(session.dispose);
      await session.bootstrap();
      await session.installTrustedScript(p, approvedDigest: p.digest);
      await session.selectTrustedScriptSchool(p.manifest.id);
      final ready = Completer<void>();
      final pending = session.runTrustedScript(
        p.manifest.id,
        'notice.list',
        interactive: false,
        onLog: (_, msg) {
          if (msg == 'locale_ready' && !ready.isCompleted) ready.complete();
        },
      );
      await ready.future.timeout(const Duration(seconds: 5));
      session.scriptLocale = 'fa';
      final result = await pending;
      expect(result.failureKind, isNotNull);
      expect(await session.cachedCapability('notice.list'), isNull);
      final fresh = await session.runTrustedScript(
        p.manifest.id,
        'notice.list',
        interactive: false,
      );
      expect((fresh.data as Map)['sourceSystem'], 'fa');
      expect((await session.cachedCapability('notice.list'))?.data, {
        'items': [],
        'sourceSystem': 'fa',
      });
      session.scriptLocale = 'en';
      expect(await session.latestCachedCapability('notice.list'), isNull);
    },
  );
}
