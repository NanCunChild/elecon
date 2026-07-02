// Probe-001 · 阶段一：OHOS WebView 工具链冒烟（**凭证无关**，debug-only）。
//
// 目的：在 OHOS 真机上坐实 4 件事（S1–S4，见 docs/probes/probe_001_smoke_plan.md §3），
// 全程不碰 CAS 登录、不收割 session、不落盘任何 JSESSIONID 级凭证：
//   S1 WebView 能加载（onLoadStop 触发、可见渲染）
//   S2 cookie 宿主可读（onLoadStop 后 CookieManager.getCookies 非空）
//   S3 导航回调触发（shouldOverrideUrlLoading 被调用、能拿 URL、CANCEL 能拦下）
//   S4 incognito 实例可建（incognito:true 能加载、销毁不崩）
//
// 🔒 边界：本屏刻意不触红线 #1。完整探针（① HttpOnly 穿透读 CAS JSESSIONID、② navigationAllow
//    闭锁收割、③ incognito 隔离/残留压测）= 下一阶段人工主导（AGENTS §1，AI 不独自闭环）。
// 本文件仅由 --dart-define=OHOS_PROBE=true 编译期门禁引入（见 main.dart），release 常量 false
// → tree-shake 整屏剔除（红线 #4/#5：探针路径不进发版二进制）。
//
// cookie 值一律打码后展示/记录（红线 #8：不提交/不外泄真实凭证态数据）。

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 冒烟标的：公开、无登录页（凭证无关）。可在屏内改。默认取西电公开站（与 notice.list 同域、零凭证）。
const String _kDefaultTarget = 'https://www.xidian.edu.cn/';

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

/// 单个 S 项的判定状态。
enum _Check { pending, pass, fail }

class _ProbeScreen extends StatefulWidget {
  const _ProbeScreen();

  @override
  State<_ProbeScreen> createState() => _ProbeScreenState();
}

class _ProbeScreenState extends State<_ProbeScreen> {
  final TextEditingController _url = TextEditingController(text: _kDefaultTarget);
  final List<String> _log = <String>[];
  final Map<String, _Check> _s = <String, _Check>{
    'S1 加载': _Check.pending,
    'S2 cookie': _Check.pending,
    'S3 导航拦截': _Check.pending,
    'S4 incognito': _Check.pending,
  };

  InAppWebViewController? _controller;
  bool _incognito = false;
  // S3：拦截首次由用户点击触发的跳转（避免把初始加载算成导航）。
  bool _armInterceptNextNav = false;

  void _mark(String key, _Check v) => setState(() => _s[key] = v);

  void _logLine(String line) {
    final String ts = DateTime.now().toIso8601String().substring(11, 23);
    setState(() => _log.insert(0, '[$ts] $line'));
    debugPrint('[ohos-probe] $line');
  }

  /// 打码：只留 cookie 名与值长度，绝不外露值本身（红线 #8）。
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

  // S2：cookie 必须等 onLoadStop 后读（Set-Cookie 走内核异步队列，过早读空串——调研时序坑）。
  Future<void> _readCookiesAfterLoad(WebUri? url) async {
    if (url == null) return;
    try {
      final cookies =
          await CookieManager.instance().getCookies(url: url);
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
    final WebUri target = WebUri(_url.text.trim().isEmpty ? _kDefaultTarget : _url.text.trim());
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
            return Chip(avatar: Icon(i, color: c, size: 18), label: Text(e.key));
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
            // S3：点此后下一次站内跳转会被 shouldOverrideUrlLoading 拦下（CANCEL）。
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
        // key 绑 incognito：切换时重建实例（S4：以 incognito:true 建实例能加载、销毁不崩）。
        key: ValueKey<bool>(_incognito),
        initialUrlRequest: URLRequest(url: target),
        initialSettings: InAppWebViewSettings(
          incognito: _incognito,
          isInspectable: kDebugMode,
          javaScriptEnabled: true,
        ),
        onWebViewCreated: (c) {
          _controller = c;
          // 时序锚：UA/JS 注入须在 controller attach 且 src 仍空时设（调研）。此处仅冒烟，不注入。
          _logLine('onWebViewCreated（incognito=$_incognito）');
        },
        onLoadStop: (c, url) async {
          _logLine('S1 onLoadStop ← $url');
          _mark('S1 加载', _Check.pass);
          if (_incognito) _mark('S4 incognito', _Check.pass);
          await _readCookiesAfterLoad(url); // S2 必须在此之后读
        },
        onReceivedError: (c, req, err) {
          _logLine('onReceivedError ${req.url} → ${err.type} ${err.description}');
          _mark('S1 加载', _Check.fail);
        },
        // S3：主框架 + 302/303 每跳都触发；return CANCEL 抢占拦下（锚 onOverrideUrlLoading，
        // 非 onLoadIntercept——后者对被动 302 不敏感，调研结论）。
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
        // SSL 异常须显式处理（调研：否则白屏/加载中断）。冒烟标的为可信公开站，proceed。
        onReceivedServerTrustAuthRequest: (c, challenge) async {
          _logLine('serverTrustAuth ← ${challenge.protectionSpace.host}（PROCEED）');
          return ServerTrustAuthResponse(
              action: ServerTrustAuthResponseAction.PROCEED);
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
                    icon: const Icon(Icons.delete_sweep, color: Colors.white54, size: 18),
                    onPressed: () => setState(_log.clear),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                reverse: true,
                itemCount: _log.length,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  child: SelectableText(
                    _log[i],
                    style: const TextStyle(
                        color: Colors.greenAccent, fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
}
