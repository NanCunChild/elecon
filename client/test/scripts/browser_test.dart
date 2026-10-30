import 'dart:async';
import 'dart:convert';

import 'package:elecon/core/scripts/browser.dart';
import 'package:elecon/core/scripts/network_policy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:elecon/ui/scripts/script_browser_page.dart';
import 'package:elecon/ui/scripts/bundled_scripts.dart';

class _Driver implements ScriptBrowserDriver {
  _Driver(this.bridge);
  final ScriptBrowserBridge bridge;
  final loads = <String>[];
  final evaluations = <String>[];
  void Function(String)? onEvaluate;
  void Function(String)? onLoad;
  Future<List<Map<String, Object?>>> Function(Uri)? readCookies;
  Completer<void>? cleanup;
  int closes = 0;
  int cookieReads = 0;
  int focusClears = 0;
  final restoredCookies = <Map<String, Object?>>[];
  final cookieRestoreUrls = <String>[];
  Completer<void>? cookieWriteGate;
  bool closing = false;
  Future<void> cookieWrites = Future.value();
  Completer<void>? initializing;

  @override
  Future<void> initialize() async => await initializing?.future;

  @override
  Future<void> loadUrl(String url) async {
    loads.add(url);
    if (onLoad != null) {
      onLoad!(url);
    } else {
      bridge.navigationStarted(url);
      bridge.navigationFinished(url);
    }
  }

  @override
  Future<void> evaluate(String source) async {
    evaluations.add(source);
    onEvaluate?.call(source);
  }

  @override
  Future<List<Map<String, Object?>>> cookies(Uri url) async {
    cookieReads++;
    return readCookies == null
        ? [
            {'name': 'session', 'value': 'SYNTHETIC'},
          ]
        : await readCookies!(url);
  }

  @override
  Future<void> setCookies(String url, List<Map<String, Object?>> cookies) {
    cookieRestoreUrls.add(url);
    return cookieWrites = (() async {
      await cookieWriteGate?.future;
      if (!closing) restoredCookies.addAll(cookies);
    })();
  }

  @override
  Future<void> stopLoading() async {}

  @override
  Future<void> clearFocus() async {
    focusClears++;
  }

  @override
  Future<void> close() async {
    closes++;
    closing = true;
    await initializing?.future;
    await cookieWrites;
    await cleanup?.future;
  }

  static String nonce(String source) =>
      jsonDecode(
            RegExp(r'const nonce = ("[^"]+");').firstMatch(source)!.group(1)!,
          )
          as String;

  void reply(String source, Object? data) => bridge.receiveResult({
    'nonce': nonce(source),
    'ok': true,
    'json': jsonEncode(data),
  });
}

Matcher code(String expected) =>
    isA<ScriptBrowserException>().having((e) => e.code, 'code', expected);

void main() {
  late ScriptBrowserBridge bridge;
  late _Driver driver;
  final policy = ScriptNetworkPolicy.fromJson({
    'origins': ['https://school.example', 'https://sso.school.example'],
  });

  setUp(() {
    bridge = ScriptBrowserBridge(policy: policy, available: true);
    driver = _Driver(bridge);
  });
  tearDown(() async => bridge.close());

  Future<void> ready() async {
    bridge.attach(driver);
    await bridge.open('https://school.example/page?ticket=SYNTHETIC');
  }

  test(
    'busy status survives allowed navigation and clears on error or close',
    () async {
      await ready();
      for (final bad in [null, 'true', 1, <String, Object?>{}]) {
        await expectLater(
          bridge.call('setBusy', {'busy': bad}),
          throwsA(code('browser_invalid_argument')),
        );
      }
      await bridge.call('setBusy', {'busy': true});
      expect(bridge.busy.value, isTrue);
      expect(driver.focusClears, 1);
      bridge.navigationStarted('https://sso.school.example/continue');
      bridge.navigationFinished('https://sso.school.example/continue');
      expect(bridge.busy.value, isTrue);
      expect(driver.focusClears, 2);
      bridge.reportError();
      expect(bridge.busy.value, isFalse);
      await bridge.call('setBusy', {'busy': true});
      expect(bridge.navigationStarted('https://outside.example/'), isFalse);
      expect(bridge.busy.value, isFalse);
      await bridge.call('setBusy', {'busy': true});
      await bridge.close();
      expect(bridge.busy.value, isFalse);
      await expectLater(
        bridge.call('setBusy', {'busy': true}),
        throwsA(code('browser_closed')),
      );
    },
  );

  testWidgets(
    'login overlay blocks school controls while cancellation remains available',
    (tester) async {
      var schoolTaps = 0;
      var cancellations = 0;
      final busy = ValueNotifier(false);
      final schoolFocus = FocusNode();
      final semantics = tester.ensureSemantics();
      addTearDown(busy.dispose);
      addTearDown(schoolFocus.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              leading: IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Cancel',
                onPressed: () => cancellations++,
              ),
            ),
            body: ValueListenableBuilder<bool>(
              valueListenable: busy,
              builder: (_, value, _) => ScriptBrowserBusyOverlay(
                busy: value,
                label: 'Signing in',
                child: Center(
                  child: TextButton(
                    focusNode: schoolFocus,
                    onPressed: () => schoolTaps++,
                    child: const Text('School control'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      schoolFocus.requestFocus();
      await tester.pump();
      expect(schoolFocus.hasFocus, isTrue);
      busy.value = true;
      await tester.pump();
      expect(schoolFocus.hasFocus, isFalse);
      expect(find.semantics.byLabel('School control'), findsNothing);
      await tester.tap(find.text('School control'), warnIfMissed: false);
      expect(schoolTaps, 0);
      expect(find.text('Signing in'), findsOneWidget);
      await tester.tap(find.byTooltip('Cancel'));
      expect(cancellations, 1);
      busy.value = false;
      await tester.pump();
      expect(find.semantics.byLabel('School control'), findsOneWidget);
      await tester.tap(find.text('School control'));
      expect(schoolTaps, 1);
      semantics.dispose();
    },
  );

  test(
    'bundled E-Hall explicitly admits its HTTP page without changing its scheme',
    () async {
      for (final school in bundledScriptSchools) {
        final package = (await school.load()).single;
        final browser = ScriptBrowserBridge(
          policy: package.manifest.network,
          available: true,
        );
        final native = _Driver(browser);
        browser.attach(native);
        const target =
            'http://ehall.xidian.edu.cn/jwapp/sys/wdkb/index.do?ticket=SYNTHETIC';
        try {
          expect(
            scriptBrowserNavigationPolicy(
              browser,
              target,
              isForMainFrame: true,
            ),
            NavigationActionPolicy.ALLOW,
          );
          await browser.open(target);
          expect(native.loads, [target]);
          expect(browser.state.value.origin, 'http://ehall.xidian.edu.cn');
          for (final denied in [
            'http://ehall.xidian.edu.cn:8080/path',
            'http://ehall.xidian.edu.cn.evil.example/path',
            'http://ids.xidian.edu.cn/authserver/login',
          ]) {
            expect(
              package.manifest.network.allowsUrl(Uri.parse(denied)),
              isFalse,
            );
          }
        } finally {
          await browser.close();
        }
      }
      expect(
        scriptBrowserNavigationPolicy(
          bridge,
          'http://school.example/page',
          isForMainFrame: true,
        ),
        NavigationActionPolicy.CANCEL,
      );
    },
  );

  test(
    'both bundled login policies admit the witnessed campus card OAuth redirects',
    () async {
      for (final school in bundledScriptSchools) {
        final packages = await school.load();
        final login = packages.singleWhere(
          (package) => package.manifest.browser,
        );
        final browser = ScriptBrowserBridge(
          policy: login.manifest.network,
          available: true,
        );
        final native = _Driver(browser);
        browser.attach(native);
        final origins = <String?>[];
        browser.state.addListener(
          () => origins.add(browser.state.value.origin),
        );
        native.onLoad = (_) {
          for (final url in [
            'https://v8scan.xidian.edu.cn/home/openXDOAuth2Page',
            'https://xxcapp.xidian.edu.cn/oauth/authorize?code=SYNTHETIC',
            'https://ids.xidian.edu.cn:443/authserver/login?service=SYNTHETIC',
            'https://xxcapp.xidian.edu.cn/callback?ticket=SYNTHETIC',
            'https://v8scan.xidian.edu.cn/home/openHomePage?openid=SYNTHETIC',
          ]) {
            expect(browser.navigationStarted(url), isTrue);
          }
          browser.navigationFinished(
            'https://v8scan.xidian.edu.cn/home/openHomePage?openid=SYNTHETIC',
          );
        };
        try {
          await browser.open(
            'https://v8scan.xidian.edu.cn/home/openXDOAuth2Page',
          );
          expect(browser.state.value.phase, ScriptBrowserPhase.ready);
          expect(origins, contains('https://xxcapp.xidian.edu.cn'));
          expect(origins.join(), isNot(contains('SYNTHETIC')));
          expect(
            browser.navigationStarted(
              'https://xxcapp.xidian.edu.cn.evil.example/?token=SYNTHETIC',
            ),
            isFalse,
          );
          expect(browser.state.value.phase, ScriptBrowserPhase.blocked);
        } finally {
          await browser.close();
        }
      }
    },
  );

  test(
    'native blank-page callbacks are cancelled without presenting a false origin failure',
    () async {
      expect(
        scriptBrowserNavigationPolicy(
          bridge,
          'about:blank',
          isForMainFrame: true,
        ),
        NavigationActionPolicy.CANCEL,
      );
      expect(bridge.state.value.phase, ScriptBrowserPhase.waiting);
      await ready();
      expect(
        scriptBrowserNavigationPolicy(
          bridge,
          'about:blank',
          isForMainFrame: true,
        ),
        NavigationActionPolicy.CANCEL,
      );
      expect(bridge.state.value.phase, ScriptBrowserPhase.ready);
      expect(bridge.state.value.origin, 'https://school.example');
      expect(
        scriptBrowserNavigationPolicy(
          bridge,
          'https://other.example/?ticket=SYNTHETIC',
          isForMainFrame: true,
        ),
        NavigationActionPolicy.CANCEL,
      );
      expect(bridge.state.value.phase, ScriptBrowserPhase.blocked);
    },
  );

  test('exclusive lease is shared, released idempotently, and reusable', () {
    final lease = ScriptBrowserLease.tryAcquire('legacy-login')!;
    expect(ScriptBrowserLease.busy, isTrue);
    expect(() => bridge.prepare(), throwsA(code('browser_busy')));
    lease.release();
    lease.release();
    bridge.prepare();
    expect(ScriptBrowserLease.tryAcquire('legacy-login'), isNull);
  });

  test(
    'unsupported platform and IP-constrained page mode never acquire lease',
    () async {
      final unsupported = ScriptBrowserBridge(policy: policy, available: false);
      expect(() => unsupported.prepare(), throwsA(code('browser_unavailable')));
      expect(ScriptBrowserLease.busy, isFalse);
      await unsupported.close();
      final constrained = ScriptBrowserBridge(
        policy: ScriptNetworkPolicy.fromJson({
          'origins': ['https://school.example'],
          'ipAllow': [],
        }),
        available: true,
      );
      expect(
        () => constrained.prepare(),
        throwsA(code('browser_ip_policy_unsupported')),
      );
      expect(ScriptBrowserLease.busy, isFalse);
      await constrained.close();
    },
  );

  test('open waits for native attachment and presents origin only', () async {
    final opened = bridge.open(
      'https://school.example/path?token=SYNTHETIC#secret',
    );
    await pumpEventQueue();
    bridge.attach(driver);
    await opened;
    expect(driver.loads, [
      'https://school.example/path?token=SYNTHETIC#secret',
    ]);
    expect(bridge.state.value.origin, 'https://school.example');
    expect(bridge.state.value.phase, ScriptBrowserPhase.ready);
  });

  test('origin escape is refused before invoking native driver', () async {
    bridge.attach(driver);
    await expectLater(
      bridge.open('https://school.example.evil/path?token=SYNTHETIC'),
      throwsA(code('browser_navigation_blocked')),
    );
    expect(driver.loads, isEmpty);
    expect(bridge.navigationStarted('javascript:alert(1)'), isFalse);
    expect(bridge.navigationStarted('https://school.example:444/'), isFalse);
  });

  test(
    'blocked diagnostics strip secrets and survive native cancellation callbacks',
    () async {
      await ready();
      expect(
        bridge.navigationStarted(
          'https://user:SYNTHETIC@other.example:444/secret;ticket=SYNTHETIC?token=SYNTHETIC#SYNTHETIC',
        ),
        isFalse,
      );
      expect(bridge.state.value.origin, 'https://other.example:444');
      bridge.reportError();
      bridge.navigationFinished('https://school.example/stale');
      expect(bridge.state.value.phase, ScriptBrowserPhase.blocked);
      await expectLater(
        bridge.evaluate('1'),
        throwsA(code('browser_navigation_blocked')),
      );
      expect(bridge.navigationStarted('custom:SYNTHETIC'), isFalse);
      expect(bridge.state.value.origin, isNull);
      expect(bridge.navigationStarted('https://school.example/retry'), isTrue);
      bridge.navigationFinished('https://school.example/retry');
      expect(bridge.state.value.phase, ScriptBrowserPhase.ready);
    },
  );

  test('allowed redirects settle open; external redirect rejects it', () async {
    bridge.attach(driver);
    driver.onLoad = (_) {
      bridge.navigationStarted('https://sso.school.example/login');
      bridge.navigationFinished('https://sso.school.example/login');
    };
    await bridge.open('https://school.example/');
    expect(bridge.state.value.origin, 'https://sso.school.example');
    driver.onLoad = (_) =>
        bridge.navigationStarted('https://other.example/?token=SYNTHETIC');
    await expectLater(
      bridge.open('https://school.example/'),
      throwsA(code('browser_navigation_blocked')),
    );
    expect(bridge.state.value.origin, 'https://other.example');
  });

  test(
    'evaluate awaits a nonce-matched promise completion, ignores forged/replayed replies',
    () async {
      await ready();
      final result = bridge.evaluate('Promise.resolve({ok: true})');
      var done = false;
      result.then((_) => done = true);
      await pumpEventQueue();
      final source = driver.evaluations.single;
      expect(source, contains('Promise.resolve().then'));
      bridge.receiveResult({'nonce': 'forged', 'ok': true, 'json': '"evil"'});
      await pumpEventQueue();
      expect(done, isFalse);
      driver.reply(source, {'ok': true});
      expect(await result, {'ok': true});
      bridge.receiveResult({
        'nonce': _Driver.nonce(source),
        'ok': true,
        'json': '"replay"',
      });
      final second = bridge.evaluate('2');
      await pumpEventQueue();
      driver.reply(driver.evaluations.last, 2);
      expect(await second, 2);
    },
  );

  test(
    'DOM helpers JSON-encode selectors and validate bounded controls',
    () async {
      await ready();
      driver.onEvaluate = (source) => driver.reply(source, true);
      const selector = 'a[data-x="\');window.bad=1;//"]\n';
      await bridge.call('exists', {'selector': selector});
      final sourceLiteral = RegExp(
        r'\(0,eval\)\((.+)\)\)\.then',
      ).firstMatch(driver.evaluations.last)!.group(1)!;
      final pageSource = jsonDecode(sourceLiteral) as String;
      expect(pageSource, contains(jsonEncode([selector])));
      await bridge.call('waitFor', {'selector': '#ready', 'timeout': 250});
      expect(driver.evaluations.last, contains('MutationObserver'));
      await expectLater(
        bridge.call('queryAll', {'selector': 'a', 'limit': 1001}),
        throwsA(code('browser_invalid_argument')),
      );
      await expectLater(
        bridge.call('waitFor', {'selector': 'a', 'timeout': 30001}),
        throwsA(code('browser_invalid_argument')),
      );
      await expectLater(
        bridge.call('unknown', {}),
        throwsA(code('browser_unknown_method')),
      );
    },
  );

  test('navigation invalidates pending page results', () async {
    await ready();
    final result = bridge.evaluate('document.title');
    final rejected = expectLater(
      result,
      throwsA(code('browser_navigation_changed')),
    );
    await pumpEventQueue();
    bridge.navigationStarted('https://sso.school.example/login');
    driver.reply(driver.evaluations.single, 'old page');
    await rejected;
  });

  test(
    'close rejects waiting attachment and pending calls, retaining lease through cleanup',
    () async {
      await ready();
      final result = bridge.evaluate('new Promise(() => {})');
      final rejected = expectLater(result, throwsA(code('browser_closed')));
      await pumpEventQueue();
      driver.cleanup = Completer<void>();
      final closing = bridge.close();
      await rejected;
      expect(ScriptBrowserLease.tryAcquire('legacy-login'), isNull);
      driver.cleanup!.complete();
      await closing;
      expect(ScriptBrowserLease.busy, isFalse);
      await bridge.close();
      expect(driver.closes, 1);
    },
  );

  test('close rejects open waiting for a platform view', () async {
    final opening = bridge.open('https://school.example/');
    final rejected = expectLater(opening, throwsA(code('browser_closed')));
    await pumpEventQueue();
    await bridge.close();
    await rejected;
  });

  test(
    'result size uses UTF-8 bytes and source limit precedes native execution',
    () async {
      await ready();
      final result = bridge.evaluate('"result"');
      final rejected = expectLater(
        result,
        throwsA(code('browser_result_too_large')),
      );
      await pumpEventQueue();
      bridge.receiveResult({
        'nonce': _Driver.nonce(driver.evaluations.single),
        'ok': true,
        'json': jsonEncode('学' * 400000),
      });
      await rejected;
      final count = driver.evaluations.length;
      await expectLater(
        bridge.evaluate('x' * (256 * 1024 + 1)),
        throwsA(code('browser_source_too_large')),
      );
      expect(driver.evaluations.length, count);
    },
  );

  test(
    'malformed page result and page exceptions expose stable codes only',
    () async {
      await ready();
      driver.onEvaluate = (source) => bridge.receiveResult({
        'nonce': _Driver.nonce(source),
        'ok': true,
        'json': 'invalid',
      });
      await expectLater(
        bridge.evaluate('1'),
        throwsA(code('browser_invalid_result')),
      );
      driver.onEvaluate = (source) => bridge.receiveResult({
        'nonce': _Driver.nonce(source),
        'ok': false,
        'error': 'SYNTHETIC_SECRET',
      });
      await expectLater(
        bridge.evaluate('1'),
        throwsA(code('browser_page_script_failed')),
      );
    },
  );

  test(
    'cookies read allowed origins and never deliver late results after close',
    () async {
      await ready();
      expect(await bridge.call('cookies', {}), [
        {'name': 'session', 'value': 'SYNTHETIC'},
      ]);
      await expectLater(
        bridge.call('cookies', {'url': 'https://other.example/'}),
        throwsA(code('browser_navigation_blocked')),
      );
      final pending = Completer<List<Map<String, Object?>>>();
      driver.readCookies = (_) => pending.future;
      final result = bridge.call('cookies', {});
      final rejected = expectLater(result, throwsA(code('browser_closed')));
      await pumpEventQueue();
      await bridge.close();
      pending.complete([
        {'name': 'old', 'value': 'SYNTHETIC'},
      ]);
      await rejected;
    },
  );

  test('evaluation has a wall timeout and releases pending slot', () async {
    await bridge.close();
    bridge = ScriptBrowserBridge(
      policy: policy,
      available: true,
      evaluateTimeout: const Duration(milliseconds: 20),
    );
    driver = _Driver(bridge);
    await ready();
    await expectLater(
      bridge.evaluate('new Promise(() => {})'),
      throwsA(code('browser_evaluate_failed')),
    );
    driver.onEvaluate = (source) => driver.reply(source, 'ready');
    expect(await bridge.evaluate('"ready"'), 'ready');
  });
  test(
    'native session initialization completes before any cookie access',
    () async {
      driver.initializing = Completer<void>();
      bridge.attach(driver);
      final cookies = bridge.call('cookies', {
        'url': 'https://school.example/',
      });
      await pumpEventQueue();
      expect(driver.cookieReads, 0);
      driver.initializing!.complete();
      expect(await cookies, [
        {'name': 'session', 'value': 'SYNTHETIC'},
      ]);
      expect(driver.cookieReads, 1);
    },
  );

  test(
    'close during initialization retains lease and rejects calls immediately',
    () async {
      driver.initializing = Completer<void>();
      bridge.attach(driver);
      final cookies = bridge.call('cookies', {
        'url': 'https://school.example/',
      });
      final rejected = expectLater(cookies, throwsA(code('browser_closed')));
      await pumpEventQueue();
      final closing = bridge.close();
      await rejected;
      expect(ScriptBrowserLease.busy, isTrue);
      driver.initializing!.complete();
      await closing;
      expect(driver.cookieReads, 0);
      expect(ScriptBrowserLease.busy, isFalse);
    },
  );

  testWidgets(
    'unsupported page shows supplied labels and closes without native view',
    (tester) async {
      final previousLogging =
          PlatformInAppWebViewController.debugLoggingSettings;
      addTearDown(() {
        PlatformInAppWebViewController.debugLoggingSettings = previousLogging;
      });
      PlatformInAppWebViewController.debugLoggingSettings =
          DebugLoggingSettings(enabled: true, usePrint: true);
      final printed = <String>[];
      void emitRawPluginResult() => runZoned(
        () => debugLog(
          debugLoggingSettings:
              PlatformInAppWebViewController.debugLoggingSettings,
          className: 'WebView',
          method: ScriptBrowserBridge.resultHandler,
          args: ['EXAMPLE_SYNTHETIC_PASSWORD'],
        ),
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => printed.add(line),
        ),
      );
      emitRawPluginResult();
      expect(printed.single, contains('EXAMPLE_SYNTHETIC_PASSWORD'));
      printed.clear();
      await bridge.close();
      bridge = ScriptBrowserBridge(policy: policy, available: false);
      const labels = ScriptBrowserPageLabels(
        title: 'School page',
        close: 'Close',
        loading: 'Loading',
        signingIn: 'Signing in',
        blocked: 'Blocked',
        failed: 'Failed',
        unavailable: 'Unavailable',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        ScriptBrowserPage(bridge: bridge, labels: labels),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      emitRawPluginResult();
      expect(printed, isEmpty);
      expect(find.text('School page'), findsOneWidget);
      expect(find.text('Unavailable'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('trusted_script_browser')),
        findsNothing,
      );
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Open'), findsOneWidget);
      expect(bridge.state.value.phase, ScriptBrowserPhase.closed);
    },
  );
  test(
    'server trust preserves Apple validation and refuses Android SSL errors',
    () {
      expect(scriptBrowserServerTrustResponse(TargetPlatform.iOS), isNull);
      expect(scriptBrowserServerTrustResponse(TargetPlatform.macOS), isNull);
      expect(
        scriptBrowserServerTrustResponse(TargetPlatform.android)?.action,
        ServerTrustAuthResponseAction.CANCEL,
      );
    },
  );
  test(
    'saved cookies restore before open and preserve HttpOnly expiry metadata',
    () async {
      bridge.attach(driver);
      await bridge.call('setCookies', {
        'url': 'https://school.example/login',
        'cookies': [
          {
            'name': 'sid',
            'value': 'SYNTHETIC_RESTORED',
            'domain': '.school.example',
            'path': '/',
            'expiresDate': 2000000000000,
            'isSecure': true,
            'isHttpOnly': true,
          },
        ],
      });
      expect(driver.loads, isEmpty);
      expect(driver.cookieRestoreUrls, ['https://school.example/login']);
      expect(driver.restoredCookies.single, {
        'name': 'sid',
        'value': 'SYNTHETIC_RESTORED',
        'domain': 'school.example',
        'path': '/',
        'expiresDate': 2000000000000,
        'isSecure': true,
        'isHttpOnly': true,
      });
      await bridge.open('https://school.example/home');
      expect(bridge.state.value.phase, ScriptBrowserPhase.ready);
    },
  );

  test(
    'cookie restore rejects origin/domain escapes and malformed batches before driver access',
    () async {
      bridge.attach(driver);
      await expectLater(
        bridge.call('setCookies', {
          'url': 'https://other.example',
          'cookies': [
            {'name': 'sid', 'value': 'SYNTHETIC'},
          ],
        }),
        throwsA(code('browser_navigation_blocked')),
      );
      for (final cookie in <Map<String, Object?>>[
        {'name': 'sid', 'value': 'SYNTHETIC', 'domain': 'other.example'},
        {'name': 'bad;name', 'value': 'SYNTHETIC'},
        {'name': 'sid', 'value': 'SYNTHETIC; injected=true'},
        {'name': 'sid', 'value': 'SYNTHETIC', 'path': 'relative'},
        {'name': 'sid', 'value': 'SYNTHETIC', 'expiresDate': -1},
        {'name': 'sid', 'value': 'SYNTHETIC', 'isHttpOnly': 'yes'},
      ]) {
        await expectLater(
          bridge.call('setCookies', {
            'url': 'https://school.example',
            'cookies': [cookie],
          }),
          throwsA(code('browser_invalid_cookie')),
        );
      }
      await expectLater(
        bridge.call('setCookies', {
          'url': 'https://school.example',
          'cookies': List.generate(101, (_) => {'name': 'sid', 'value': 'x'}),
        }),
        throwsA(code('browser_cookie_limit')),
      );
      await expectLater(
        bridge.call('setCookies', {
          'url': 'https://school.example',
          'cookies': [
            {'name': 'sid', 'value': 'x' * 65536},
          ],
        }),
        throwsA(code('browser_cookie_limit')),
      );
      expect(driver.cookieRestoreUrls, isEmpty);
    },
  );

  test(
    'close cancels cookie restore and retains lease through pending native writes',
    () async {
      bridge.attach(driver);
      driver.cookieWriteGate = Completer<void>();
      final restore = bridge.call('setCookies', {
        'url': 'https://school.example',
        'cookies': [
          {'name': 'sid', 'value': 'LATE_SYNTHETIC'},
        ],
      });
      final cancelled = expectLater(restore, throwsA(code('browser_closed')));
      await pumpEventQueue();
      final closing = bridge.close();
      await cancelled;
      expect(ScriptBrowserLease.busy, isTrue);
      driver.cookieWriteGate!.complete();
      await closing;
      expect(driver.restoredCookies, isEmpty);
      expect(ScriptBrowserLease.busy, isFalse);
    },
  );
  test(
    'cookie restore retains SameSite and rejects None without Secure',
    () async {
      bridge.attach(driver);
      for (final sameSite in ['Lax', 'Strict', 'None']) {
        await bridge.call('setCookies', {
          'url': 'https://school.example/notices',
          'cookies': [
            {
              'name': 'sid',
              'value': 'SYNTHETIC',
              'sameSite': sameSite,
              'isSecure': true,
            },
          ],
        });
        expect(driver.restoredCookies.last['sameSite'], sameSite);
        expect(driver.restoredCookies.last['isSecure'], isTrue);
      }
      final writes = driver.cookieRestoreUrls.length;
      for (final cookie in <Map<String, Object?>>[
        {
          'name': 'sid',
          'value': 'SYNTHETIC',
          'sameSite': 'None',
          'isSecure': false,
        },
        {'name': 'sid', 'value': 'SYNTHETIC', 'sameSite': 'none'},
      ]) {
        await expectLater(
          bridge.call('setCookies', {
            'url': 'https://school.example/notices',
            'cookies': [cookie],
          }),
          throwsA(code('browser_invalid_cookie')),
        );
      }
      expect(driver.cookieRestoreUrls.length, writes);
    },
  );

  test(
    'None on HTTP without explicit Secure fails before native mutation',
    () async {
      final plain = ScriptBrowserBridge(
        policy: ScriptNetworkPolicy.fromJson({
          'origins': ['http://school.example'],
        }),
        available: true,
      );
      final native = _Driver(plain);
      plain.attach(native);
      try {
        await expectLater(
          plain.call('setCookies', {
            'url': 'http://school.example',
            'cookies': [
              {'name': 'sid', 'value': 'SYNTHETIC', 'sameSite': 'None'},
            ],
          }),
          throwsA(code('browser_invalid_cookie')),
        );
        expect(native.cookieRestoreUrls, isEmpty);
      } finally {
        await plain.close();
      }
    },
  );
}
