// Probe-001 · 阶段一：OHOS WebView 工具链冒烟（**凭证无关**，debug-only）。
//
// 本入口只由 tools/ohos/build-hap.sh 在 Flutter-OHOS SDK + pubspec.ohos.yaml
// 路线下编译。主线 Android/iOS/桌面不解析本文件，也不依赖 flutter_inappwebview。

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

void runOhosWebViewProbe() {
  runApp(const OhosWebViewProbeApp());
}

/// 冒烟标的：公开、无登录页（凭证无关）。可在屏内改。默认取西电公开站（与 notice.list 同域、零凭证）。
const String _kDefaultTarget = 'https://www.xidian.edu.cn/';

/// TLS 证书异常放行白名单：仅冒烟标的 host（校园站真机侧常见中间链缺失）。
const Set<String> _kTlsProceedHosts = <String>{'www.xidian.edu.cn'};

class OhosWebViewProbeApp extends StatelessWidget {
  const OhosWebViewProbeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'elecon · OHOS WebView Probe',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: const _ProbeScreen(),
    );
  }
}

enum _Check { pending, pass, fail }

class _ProbeScreen extends StatefulWidget {
  const _ProbeScreen();

  @override
  State<_ProbeScreen> createState() => _ProbeScreenState();
}

class _ProbeScreenState extends State<_ProbeScreen> {
  final TextEditingController _url =
      TextEditingController(text: _kDefaultTarget);
  final List<String> _log = <String>[];
  final Map<String, _Check> _s = <String, _Check>{
    'S1 加载': _Check.pending,
    'S2 cookie': _Check.pending,
    'S3 导航拦截': _Check.pending,
    'S4 incognito': _Check.pending,
  };

  InAppWebViewController? _controller;
  bool _incognito = false;
  bool _armInterceptNextNav = false;

  void _mark(String key, _Check v) => setState(() => _s[key] = v);

  void _logLine(String line) {
    final String ts = DateTime.now().toIso8601String().substring(11, 23);
    setState(() => _log.insert(0, '[$ts] $line'));
    debugPrint('[ohos-probe] $line');
  }

  String _maskCookies(List<Cookie> cookies) {
    if (cookies.isEmpty) return '(空)';
    return cookies
        .map((c) => '${c.name}=<${(c.value?.length ?? 0)}B masked>')
        .join('; ');
  }

  Future<void> _reload() async {
    _mark('S1 加载', _Check.pending);
    _mark('S2 cookie', _Check.pending);
    final String u = _url.text.trim();
    _logLine('load → $u  (incognito=$_incognito)');
    await _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(u)));
  }

  Future<void> _readCookiesAfterLoad(WebUri? url) async {
    if (url == null) return;
    try {
      final cookies = await CookieManager.instance().getCookies(url: url);
      _logLine('S2 getCookies(${url.host}) → ${_maskCookies(cookies)}');
      _mark('S2 cookie', cookies.isNotEmpty ? _Check.pass : _Check.fail);
    } catch (e) {
      _logLine('S2 getCookies 异常：$e');
      _mark('S2 cookie', _Check.fail);
    }
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final WebUri target =
        WebUri(_url.text.trim().isEmpty ? _kDefaultTarget : _url.text.trim());
    return Scaffold(
      appBar: AppBar(
        title: const Text('OHOS WebView Probe · S1–S4（凭证无关）'),
        actions: [
          Row(children: [
            const Text('incognito'),
            Switch(
              value: _incognito,
              onChanged: (v) {
                setState(() => _incognito = v);
                _mark('S4 incognito', _Check.pending);
                _logLine('切换 incognito=$v（重建 WebView 生效）');
              },
            ),
          ]),
        ],
      ),
      body: Column(
        children: [
          _statusBar(),
          _controlBar(),
          const Divider(height: 1),
          Expanded(
            child: Row(
              children: [
                Expanded(flex: 3, child: _webView(target)),
                const VerticalDivider(width: 1),
                Expanded(flex: 2, child: _logPanel()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusBar() => Padding(
        padding: const EdgeInsets.all(8),
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          children: _s.entries.map((e) {
            final (Color c, IconData i) = switch (e.value) {
              _Check.pending => (Colors.grey, Icons.remove_circle_outline),
              _Check.pass => (Colors.green, Icons.check_circle),
              _Check.fail => (Colors.red, Icons.cancel),
            };
            return Chip(
                avatar: Icon(i, color: c, size: 18), label: Text(e.key));
          }).toList(),
        ),
      );

  Widget _controlBar() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _url,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: '标的（公开无登录页，凭证无关）',
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(onPressed: _reload, child: const Text('加载')),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () {
                setState(() => _armInterceptNextNav = true);
                _mark('S3 导航拦截', _Check.pending);
                _logLine('S3 已武装：下一次导航将被 CANCEL 拦下——请点页面内任一链接');
              },
              child: const Text('武装 S3'),
            ),
          ],
        ),
      );

  Widget _webView(WebUri target) => InAppWebView(
        key: ValueKey<bool>(_incognito),
        initialUrlRequest: URLRequest(url: target),
        initialSettings: InAppWebViewSettings(
          incognito: _incognito,
          isInspectable: kDebugMode,
          javaScriptEnabled: true,
        ),
        onWebViewCreated: (c) {
          _controller = c;
          _logLine('onWebViewCreated（incognito=$_incognito）');
        },
        onLoadStop: (c, url) async {
          _logLine('S1 onLoadStop ← $url');
          _mark('S1 加载', _Check.pass);
          if (_incognito) _mark('S4 incognito', _Check.pass);
          await _readCookiesAfterLoad(url);
        },
        onReceivedError: (c, req, err) {
          _logLine(
              'onReceivedError ${req.url} → ${err.type} ${err.description}');
          _mark('S1 加载', _Check.fail);
        },
        shouldOverrideUrlLoading: (c, action) async {
          final WebUri? u = action.request.url;
          _logLine('S3 shouldOverrideUrlLoading ← $u');
          if (_armInterceptNextNav) {
            setState(() => _armInterceptNextNav = false);
            _mark('S3 导航拦截', _Check.pass);
            _logLine('S3 → CANCEL（已拦下 $u）');
            return NavigationActionPolicy.CANCEL;
          }
          return NavigationActionPolicy.ALLOW;
        },
        onReceivedServerTrustAuthRequest: (c, challenge) async {
          final String host = challenge.protectionSpace.host;
          final bool allowed = _kTlsProceedHosts.contains(host);
          _logLine(
              'serverTrustAuth ← $host（${allowed ? 'PROCEED·白名单' : 'CANCEL·fail-closed'}）');
          return ServerTrustAuthResponse(
            action: allowed
                ? ServerTrustAuthResponseAction.PROCEED
                : ServerTrustAuthResponseAction.CANCEL,
          );
        },
      );

  Widget _logPanel() => Container(
        color: const Color(0xFF0E1116),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(6),
              child: Row(
                children: [
                  const Text('日志（cookie 已打码）',
                      style: TextStyle(color: Colors.white70)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.delete_sweep,
                        color: Colors.white54, size: 18),
                    onPressed: () => setState(_log.clear),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Colors.white12),
            Expanded(
              child: ListView.builder(
                reverse: true,
                itemCount: _log.length,
                itemBuilder: (_, i) => Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  child: Text(
                    _log[i],
                    style: const TextStyle(
                      color: Colors.white70,
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
}
