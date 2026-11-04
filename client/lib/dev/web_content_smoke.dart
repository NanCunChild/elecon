/// Device-only synthetic entry point. No school data, credentials or requests.
/// Run with `flutter run -t lib/dev/web_content_smoke.dart`.
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../core/credential/store.dart';
import '../core/scripts/browser.dart';
import '../core/scripts/credentials.dart';
import '../core/scripts/manifest.dart';
import '../core/scripts/runtime.dart';
import '../ui/scripts/script_browser_surface.dart';
import '../ui/scripts/script_browser_platform_view.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: WebContentSmoke()));
}

class WebContentSmoke extends StatefulWidget {
  const WebContentSmoke({super.key});
  @override
  State<WebContentSmoke> createState() => _WebContentSmokeState();
}

class _WebContentSmokeState extends State<WebContentSmoke> {
  late final ScriptPackage package;
  late final ScriptBrowserBridge bridge;
  bool active = true;
  bool cancelling = false;
  String status = 'WEB_CONTENT_SMOKE_RUNNING';
  @override
  void initState() {
    super.initState();
    package = ScriptPackage.parse(
      jsonEncode({
        'format': 'elecon-script/1',
        'manifest': {
          'sdkVersion': 14,
          'accounts': [],
          'id': 'synthetic.web-smoke',
          'schoolId': 'synthetic',
          'version': '1.0.0',
          'name': 'Synthetic browser smoke',
          'browser': true,
          'network': {'origins': []},
          'capabilities': [
            {
              'id': 'web.content',
              'schema': 'elecon.web.content',
              'schemaVersion': '1.0',
            },
          ],
          'webContent': [
            {
              'id': 'smoke',
              'title': 'Synthetic form test',
              'html':
                  '''<style>body{font:20px sans-serif;padding:20px;background:white;color:black}button{font:inherit;padding:20px;display:block;margin:20px 0}</style>
<p id="sentinel">inert</p>
<script>document.querySelector('#sentinel').textContent='EXECUTED';new RTCPeerConnection();</script>
<img src="data:invalid" onerror="document.querySelector('#sentinel').textContent='EXECUTED'">
<div id="dynamic"></div><button id="submit" type="button">Submit smoke</button>
''',
            },
          ],
        },
        'source':
            r'''export const capabilities={'web.content':async(ctx,{pageId})=>{
        ctx.log('info','smoke/before_open');
        await ctx.browser.openContent(pageId);
        ctx.log('info','smoke/open_done');
        const dom=ctx.browser.content;
        if(!await dom({operation:'exists',selector:'#sentinel'})) { await dom({operation:'getText',selector:'body'}); throw new Error('smoke_sentinel_missing'); }
        if(await dom({operation:'getText',selector:'#sentinel'})!=='inert') throw new Error('smoke');
        ctx.log('info','smoke/sentinel_checked');
        ctx.log('info','smoke/before_dom');
        await dom({operation:'setHtml',selector:'#dynamic',value:'<label for="field">Synthetic value</label><input id="field">'});
        await dom({operation:'setValue',selector:'#field',value:'synthetic-fixed-value'});
        if(await dom({operation:'getValue',selector:'#field'})!=='synthetic-fixed-value') throw new Error('smoke');
        ctx.log('info','smoke/dom_checked');
        let denied=false;
        try {await ctx.browser.evaluate('new RTCPeerConnection()');}
        catch(e){denied=e.code==='browser_content_evaluate_forbidden';}
        if(!denied) throw new Error('smoke');
        ctx.log('info','smoke/evaluate_denied');
        const clicked=await dom({operation:'waitForEvent',selector:'#submit',event:'click',timeoutMs:90000});
        if(!clicked) return {pageId,status:'cancelled'};
        if(await dom({operation:'getText',selector:'#sentinel'})!=='inert') throw new Error('smoke');
        ctx.log('info','smoke/sentinel_checked');
        return {pageId,status:'completed'};
      }};''',
      }),
    );
    bridge = ScriptBrowserBridge(
      policy: package.manifest.network,
      contentOnly: true,
      contentPages: package.manifest.webContent,
      contentDigest: package.digest,
    );
    bridge.state.addListener(() {
      debugPrint(
        'WEB_CONTENT_SMOKE_BROWSER ${bridge.state.value.phase.name} ${bridge.state.value.errorCode ?? 'none'}',
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_run()));
  }

  Future<void> _run() async {
    var passed = false;
    try {
      final result = await const TrustedScriptRuntime().run(
        package: package,
        capability: 'web.content',
        params: const {'pageId': 'smoke'},
        credentials: ScriptCredentials(
          store: CredentialStore(),
          schoolId: 'synthetic',
          scriptId: package.manifest.id,
          sdkVersion: 14,
        ),
        fetch: (_, _) async => throw StateError('unexpected network'),
        browserCall: (method, arguments) async {
          if (method == 'content' && arguments['operation'] == 'waitForEvent') {
            if (mounted) setState(() => status = 'WEB_CONTENT_SMOKE_READY');
            debugPrint('WEB_CONTENT_SMOKE_READY');
          }
          try {
            final result = await bridge.call(method, arguments);
            if (method == 'content' && arguments['selector'] == '#sentinel') {
              debugPrint(
                'WEB_CONTENT_SMOKE_SENTINEL inert=${result == 'inert'} executed=${result == 'EXECUTED'} exists=${result == true}',
              );
            }
            if (method == 'content' && arguments['selector'] == 'body') {
              final body = result is String ? result : '';
              debugPrint(
                'WEB_CONTENT_SMOKE_BODY empty=${body.isEmpty} hasMarkup=${body.contains('id="sentinel"')}',
              );
              for (final code in const [
                'ERR_ACCESS_DENIED',
                'ERR_BLOCKED_BY_CLIENT',
                'ERR_CACHE_MISS',
                'ERR_NAME_NOT_RESOLVED',
                'ERR_UNKNOWN_URL_SCHEME',
              ]) {
                if (body.contains(code)) {
                  debugPrint('WEB_CONTENT_SMOKE_NATIVE_ERROR $code');
                }
              }
            }
            return result;
          } on ScriptBrowserException catch (error) {
            debugPrint('WEB_CONTENT_SMOKE_DOM_ERROR ${error.code}');
            rethrow;
          }
        },
        onLog: (_, message) {
          if (RegExp(r'^smoke/[a-z_]+$').hasMatch(message)) {
            debugPrint('WEB_CONTENT_SMOKE_STAGE $message');
          }
        },
        isActive: () => active,
        wallTimeout: const Duration(seconds: 120),
      );
      passed = result is Map && result['status'] == 'completed';
    } on ScriptRunException catch (error) {
      debugPrint('WEB_CONTENT_SMOKE_ERROR ${error.code}');
      passed =
          cancelling &&
          const {'invocation_cancelled', 'adapter_failed'}.contains(error.code);
    } catch (error) {
      debugPrint('WEB_CONTENT_SMOKE_ERROR_TYPE ${error.runtimeType}');
      passed = false;
    }
    try {
      await bridge.close();
    } catch (_) {
      passed = false;
    }
    passed = passed && !ScriptBrowserLease.busy;
    if (!mounted) return;
    setState(
      () => status = passed
          ? (cancelling
                ? 'WEB_CONTENT_SMOKE_CANCEL_PASS'
                : 'WEB_CONTENT_SMOKE_PASS')
          : 'WEB_CONTENT_SMOKE_FAIL',
    );
    debugPrint(status);
  }

  void _cancel() {
    cancelling = true;
    active = false;
    unawaited(bridge.close());
  }

  @override
  void dispose() {
    active = false;
    unawaited(bridge.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Synthetic web content smoke')),
    body: Column(
      children: [
        Text(status, key: const ValueKey('smoke-status')),
        TextButton(
          onPressed: status == 'WEB_CONTENT_SMOKE_READY' ? _cancel : null,
          child: const Text('Cancel smoke'),
        ),
        Expanded(
          child: ScriptBrowserSurface(
            bridge: bridge,
            platformViewBuilder: (_, bridge) => ScriptBrowserPlatformView(
              bridge: bridge,
              onDiagnostic: (code) =>
                  debugPrint('WEB_CONTENT_SMOKE_NATIVE $code'),
            ),
            labels: const ScriptBrowserPageLabels(
              title: 'Synthetic form test',
              close: 'Close smoke',
              loading: 'Loading',
              signingIn: 'Working',
              blocked: 'Blocked',
              failed: 'Failed',
              unavailable: 'Unavailable',
            ),
            onClosed: _cancel,
          ),
        ),
      ],
    ),
  );
}
