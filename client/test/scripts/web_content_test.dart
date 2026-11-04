import 'dart:async';
import 'dart:convert';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/scripts/browser.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/scripts/runtime.dart';
import 'package:elecon/core/scripts/web_content_dom.dart';
import 'package:elecon/ui/scripts/script_browser_platform_view.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_qjs_next/flutter_qjs.dart';

ScriptPackage package(String source, {bool pages = true}) =>
    ScriptPackage.parse(
      jsonEncode({
        'format': 'elecon-script/1',
        'manifest': {
          'sdkVersion': 14,
          'accounts': [],
          'id': 'synthetic.web',
          'schoolId': 'synthetic',
          'version': '1.0.0',
          'name': 'Synthetic form',
          'browser': true,
          'network': {
            'origins': ['https://school.example'],
          },
          'capabilities': [
            {
              'id': pages ? 'web.content' : 'notice.list',
              'schema': pages ? 'elecon.web.content' : 'elecon.notice.list',
              'schemaVersion': pages ? '1.0' : '1.1',
            },
          ],
          if (pages)
            'webContent': [
              {
                'id': 'form',
                'title': 'Form',
                'html': '<button id="send">Send</button><input id="value">',
              },
              {'id': 'other', 'title': 'Other', 'html': '<p>Other page</p>'},
            ],
        },
        'source': source,
      }),
    );
Matcher browserCode(String code) =>
    isA<ScriptBrowserException>().having((e) => e.code, 'code', code);
Matcher runCode(String code) =>
    isA<ScriptRunException>().having((e) => e.code, 'code', code);

class Driver implements ScriptBrowserDriver, ScriptBrowserContentDriver {
  Driver(this.bridge);
  final ScriptBrowserBridge bridge;
  String? html;
  final evaluated = <String>[];
  int remoteLoads = 0;
  bool autoReply = true;
  Completer<void>? closing;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> loadUrl(String url) async {
    remoteLoads++;
  }

  @override
  Future<void> loadContent(String data, String url) async {
    html = data;
    bridge.navigationStarted(url);
    bridge.navigationFinished(url);
  }

  @override
  Future<void> evaluate(String source) async {
    evaluated.add(source);
    if (autoReply) reply(source, 'value');
  }

  void reply(String source, Object? value) => bridge.receiveResult({
    'nonce': jsonDecode(
      RegExp(r'const nonce = ("[^"]+");').firstMatch(source)!.group(1)!,
    ),
    'ok': true,
    'json': jsonEncode(value),
  });
  @override
  Future<List<Map<String, Object?>>> cookies(Uri url) async =>
      throw StateError('no cookies');
  @override
  Future<void> setCookies(
    String url,
    List<Map<String, Object?>> cookies,
  ) async => throw StateError('no cookies');
  @override
  Future<void> clearFocus() async {}
  @override
  Future<void> stopLoading() async {}
  @override
  Future<void> close() async => await closing?.future;
}

class ExecutingDriver extends Driver {
  ExecutingDriver(super.bridge);
  final qjs = IsolateQjs(timeout: 5000, memoryLimit: 64 * 1024 * 1024);
  @override
  Future<void> initialize() async {
    qjs.setHostFunctions({
      'pageReply': (dynamic _, dynamic payload) {
        bridge.receiveResult(payload);
        return null;
      },
    });
    await qjs.evaluate('''globalThis.window=globalThis;
      globalThis.node={textContent:'inert',value:'initial',disabled:false};
      globalThis.document={querySelector:selector=>selector==='#missing'?null:node};
      globalThis.flutter_inappwebview={callHandler:(name,payload)=>pageReply(name,payload)};
    ''');
  }

  @override
  Future<void> evaluate(String source) async {
    evaluated.add(source);
    await qjs.evaluate(source);
  }

  @override
  Future<void> close() async {
    await qjs.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final p = package(
    "export const capabilities={'web.content':async(_,{pageId})=>({pageId,status:'cancelled'})};",
  );
  ScriptBrowserBridge bridge() => ScriptBrowserBridge(
    policy: p.manifest.network,
    available: true,
    contentOnly: true,
    contentPages: p.manifest.webContent,
    contentDigest: p.digest,
  );
  Future<Object?> run(
    ScriptPackage p, {
    String capability = 'web.content',
    Map<String, dynamic> params = const {'pageId': 'form'},
    Future<Object?> Function(String, Map<String, Object?>)? call,
  }) => const TrustedScriptRuntime().run(
    package: p,
    capability: capability,
    params: params,
    credentials: ScriptCredentials(
      store: CredentialStore(),
      schoolId: 'synthetic',
      scriptId: p.manifest.id,
      sdkVersion: 14,
    ),
    fetch: (_, _) async => throw StateError('unexpected network'),
    browserCall: call,
  );

  test(
    'local HTML uses host CSP before package bytes and native network blocking',
    () async {
      final b = bridge();
      final d = Driver(b);
      b.attach(d);
      addTearDown(b.close);
      await b.call('openContent', {'id': 'form'});
      expect(d.remoteLoads, 0);
      expect(
        d.html!.indexOf("script-src 'none'"),
        lessThan(d.html!.indexOf('<button')),
      );
      for (final directive in ['connect-src', 'form-action', 'worker-src']) {
        expect(d.html, contains("$directive 'none'"));
      }
      expect(d.html, isNot(contains('unsafe-eval')));
      final settings = scriptBrowserSettings(b);
      expect(settings.blockNetworkLoads, true);
      expect(settings.blockNetworkImage, true);
      expect(settings.allowFileAccess, false);
      expect(settings.allowContentAccess, false);
      expect(settings.domStorageEnabled, false);
      expect(settings.cacheEnabled, false);
      expect(scriptBrowserBlockedResource().statusCode, 403);
      WebResourceResponse? resource(
        String id, {
        bool main = true,
        String method = 'GET',
      }) => scriptBrowserInterceptRequest(
        b,
        WebResourceRequest(
          url: WebUri(b.contentUrl(id)),
          isForMainFrame: main,
          method: method,
        ),
      );
      final document = resource('form')!;
      expect(document.statusCode, 200);
      expect(utf8.decode(document.data!), d.html);
      expect(
        document.headers?['Content-Security-Policy'],
        scriptWebContentPolicy,
      );
      expect(resource('other')!.statusCode, 403);
      expect(resource('form', main: false)!.statusCode, 403);
      expect(resource('form', method: 'POST')!.statusCode, 403);

      for (final url in [
        'https://school.example/form',
        b.contentUrl('form'),
        'data:text/html,x',
        'javascript:alert(1)',
        'file:///x',
      ]) {
        expect(
          scriptBrowserNavigationPolicy(b, url),
          NavigationActionPolicy.CANCEL,
        );
        expect(
          scriptBrowserNavigationPolicy(b, url, isForMainFrame: false),
          NavigationActionPolicy.CANCEL,
        );
      }
      expect(b.state.value.phase, ScriptBrowserPhase.ready);
    },
  );
  test(
    'content refuses undeclared pages, remote open, cookies and author JS',
    () async {
      final b = bridge();
      final d = Driver(b);
      b.attach(d);
      addTearDown(b.close);
      await expectLater(
        b.call('openContent', {'id': 'missing'}),
        throwsA(browserCode('browser_content_undeclared')),
      );
      await b.call('openContent', {'id': 'form'});
      for (final (method, args, code)
          in <(String, Map<String, Object?>, String)>[
            (
              'open',
              {'url': 'https://school.example'},
              'browser_content_remote_forbidden',
            ),
            (
              'evaluate',
              {'source': 'new RTCPeerConnection()'},
              'browser_content_evaluate_forbidden',
            ),
            (
              'text',
              {'selector': 'body'},
              'browser_content_evaluate_forbidden',
            ),
            ('cookies', {}, 'browser_content_cookies_forbidden'),
            ('setCookies', {}, 'browser_content_cookies_forbidden'),
          ]) {
        await expectLater(b.call(method, args), throwsA(browserCode(code)));
      }
      expect(d.evaluated, isEmpty);
      expect(d.remoteLoads, 0);
    },
  );
  test(
    'fixed DOM encodes values as data and validates operations and budgets',
    () async {
      final b = bridge();
      final d = Driver(b);
      b.attach(d);
      addTearDown(b.close);
      await b.call('openContent', {'id': 'form'});
      await b.call('content', {
        'operation': 'setHtml',
        'selector': 'body',
        'value': "</script>'); new RTCPeerConnection(); //",
      });
      expect(d.evaluated.single, contains('JSON.parse('));
      expect(d.evaluated.single, isNot(contains('(0,eval)')));
      expect(d.evaluated.single, isNot(contains('new Function')));
      final invalid = <Map<String, Object?>>[
        {'operation': 'evaluate', 'selector': 'body', 'value': 'x'},
        {
          'operation': 'setAttribute',
          'selector': 'body',
          'attribute': 'onclick',
          'value': 'x',
        },
        {
          'operation': 'setText',
          'selector': 'body',
          'value': 'x',
          'source': 'x',
        },
        {'operation': 'setDisabled', 'selector': 'body', 'value': 'true'},
        {'operation': 'waitForEvent', 'selector': 'body', 'event': 'load'},
        {
          'operation': 'waitForEvent',
          'selector': 'body',
          'event': 'click',
          'timeoutMs': 90001,
        },
        {'operation': 'queryAll', 'selector': 'body', 'limit': 101},
        {'operation': 'setHtml', 'selector': 'body', 'value': 'x' * 65537},
      ];
      for (final args in invalid) {
        await expectLater(
          b.call('content', args),
          throwsA(browserCode('browser_content_invalid_operation')),
        );
      }
      expect(d.evaluated.length, 1);
      final event = ScriptContentOperation.parse({
        'operation': 'waitForEvent',
        'selector': '#send',
        'event': 'click',
      });
      expect(event.source, contains('if (!e.isTrusted) return;'));
      expect(event.source, contains('e.preventDefault()'));
      expect(event.source, contains('node.disabled = true'));
    },
  );
  test(
    'close invalidates late DOM values and retains lease through cleanup',
    () async {
      final b = bridge();
      final d = Driver(b);
      b.attach(d);
      await b.call('openContent', {'id': 'form'});
      d.autoReply = false;
      final pending = b.call('content', {
        'operation': 'getValue',
        'selector': '#value',
      });
      final failed = expectLater(
        pending,
        throwsA(browserCode('browser_closed')),
      );
      await Future<void>.delayed(Duration.zero);
      d.closing = Completer<void>();
      final closing = b.close();
      await failed;
      expect(ScriptBrowserLease.busy, true);
      d.reply(d.evaluated.single, 'late private value');
      d.closing!.complete();
      await closing;
      expect(ScriptBrowserLease.busy, false);
    },
  );
  test(
    'fixed native DOM program executes directly without eval or data code injection',
    () async {
      final b = bridge();
      final d = ExecutingDriver(b);
      b.attach(d);
      addTearDown(b.close);
      await b.call('openContent', {'id': 'form'});
      expect(
        await b.call('content', {'operation': 'getText', 'selector': '#value'}),
        'inert',
      );
      expect(
        await b.call('content', {
          'operation': 'exists',
          'selector': '#missing',
        }),
        false,
      );
      const payload = "'); globalThis.node.value='executed'; //";
      await b.call('content', {
        'operation': 'setValue',
        'selector': '#value',
        'value': payload,
      });
      expect(
        await b.call('content', {
          'operation': 'getValue',
          'selector': '#value',
        }),
        payload,
      );
    },
  );

  test(
    'real QuickJS pins requested page, result, mode and declared SDK API',
    () async {
      final calls = <String>[];
      final p = package(
        """export const capabilities={'web.content':async(ctx,{pageId})=>{
      await ctx.browser.openContent(pageId);
      const value=await ctx.browser.content({operation:'getValue',selector:'#value'});
      return {pageId,status:value==='valid'?'completed':'unknown'};
    }};""",
      );
      expect(
        await run(
          p,
          call: (method, args) async {
            calls.add(method);
            return method == 'content' ? 'valid' : null;
          },
        ),
        {'pageId': 'form', 'status': 'completed'},
      );
      expect(calls, ['openContent', 'content']);
      for (final source in [
        "await ctx.browser.openContent('other');",
        "await ctx.browser.evaluate('1');",
        "await ctx.browser.open('https://school.example');",
        "await ctx.browser.content({operation:'getText',selector:'body'});",
      ]) {
        var called = false;
        final p = package(
          "export const capabilities={'web.content':async(ctx,{pageId})=>{ $source return {pageId,status:'completed'}; }};",
        );
        await expectLater(
          run(
            p,
            call: (_, _) async {
              called = true;
              return null;
            },
          ),
          throwsA(isA<ScriptRunException>()),
        );
        expect(called, false);
      }
      await expectLater(
        run(
          package(
            "export const capabilities={'web.content':async()=>({pageId:'other',status:'completed'})};",
          ),
        ),
        throwsA(runCode('schema_validation_failed')),
      );
      await expectLater(
        run(p, params: {'pageId': 'missing'}),
        throwsA(runCode('input_invalid_request')),
      );
      final without = package(
        "export const capabilities={'notice.list':async ctx=>({items:[],sourceSystem:typeof ctx.browser.openContent+'|'+typeof ctx.browser.content})};",
        pages: false,
      );
      expect(await run(without, capability: 'notice.list', params: {}), {
        'items': [],
        'sourceSystem': 'undefined|undefined',
      });
    },
  );
}
