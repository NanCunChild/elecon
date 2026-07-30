/// Settings → 隐私政策页：内嵌只读浏览器展示官方隐私政策全文。
///
/// 信任面（红线 #1/#3）：本页是**纯公开内容**的阅读器——
/// * `incognito: true`：与登录收割用的 WebView cookie jar 完全隔离，本页不读也不写
///   任何凭证；不注入脚本、不读 cookie、不装 host-fn 通道。
/// * 主框架导航锁定官方站点 host，越站一律 CANCEL——避免内嵌浏览器退化成通用浏览器，
///   把用户带到任意站点。
///
/// 三态齐备（ui_ai_generation §2）：loading（进度条）/ error（重试 + 复制链接）/
/// loaded。占位期链接尚未上线，错误态是常态路径而非边角情形。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../app_info.dart';
import '../../l10n/gen/app_localizations.dart';

class PrivacyPolicyPage extends StatefulWidget {
  const PrivacyPolicyPage({
    super.key,
    this.url = kPrivacyPolicyUrl,
    this.viewerBuilder,
  });

  /// 隐私政策地址；默认取 [kPrivacyPolicyUrl]（当前为占位）。
  final String url;

  /// 测试注入：widget 测试环境没有 WebView 平台实现，替换掉内嵌浏览器本体，
  /// 只验证页面骨架（标题 / 占位提示 / 复制链接 / 错误态）。
  @visibleForTesting
  final Widget Function(BuildContext context)? viewerBuilder;

  @override
  State<PrivacyPolicyPage> createState() => _PrivacyPolicyPageState();
}

class _PrivacyPolicyPageState extends State<PrivacyPolicyPage> {
  /// 重试计数——变更即换 WebView 的 key，强制重建重新发起加载。
  int _attempt = 0;
  bool _loading = true;
  bool _failed = false;

  /// 允许停留的主框架 host（官方站点自身）。
  static final String _allowedHost = Uri.parse(kOfficialSiteBase).host;

  void _retry() => setState(() {
        _attempt++;
        _loading = true;
        _failed = false;
      });

  void _onFailed() {
    if (!mounted) return;
    setState(() {
      _loading = false;
      _failed = true;
    });
  }

  Future<void> _copyLink() async {
    final l10n = AppLocalizations.of(context);
    await Clipboard.setData(ClipboardData(text: widget.url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.commonLinkCopied)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.privacyTitle),
        actions: [
          IconButton(
            tooltip: l10n.commonCopyLink,
            onPressed: _copyLink,
            icon: const Icon(Icons.link_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          // 占位期声明：链接指向的正式条款尚未发布。
          Container(
            width: double.infinity,
            color: scheme.surfaceContainerHighest,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Text(
              l10n.privacyPlaceholderNotice,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ),
          if (_loading && !_failed) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _failed
                ? _PrivacyErrorView(
                    url: widget.url,
                    onRetry: _retry,
                    onCopyLink: _copyLink,
                  )
                : widget.viewerBuilder?.call(context) ?? _buildWebView(),
          ),
        ],
      ),
    );
  }

  Widget _buildWebView() {
    return InAppWebView(
      key: ValueKey('privacy_policy_$_attempt'),
      initialUrlRequest: URLRequest(url: WebUri(widget.url)),
      initialSettings: InAppWebViewSettings(
        // 与登录 WebView 的 cookie jar 隔离：本页永不接触凭证（红线 #1）。
        incognito: true,
        // 官方静态页可能由前端框架渲染，故留 JS；隔离由 incognito + host 锁承担，
        // 本页不注入任何脚本、不开 host-fn 通道。
        javaScriptEnabled: true,
        isInspectable: kDebugMode,
        useShouldOverrideUrlLoading: true,
        supportZoom: true,
      ),
      onLoadStop: (_, _) {
        if (!mounted) return;
        setState(() => _loading = false);
      },
      onReceivedError: (_, request, _) {
        if (request.isForMainFrame == false) return;
        _onFailed();
      },
      onReceivedHttpError: (_, request, response) {
        if (request.isForMainFrame == false) return;
        final status = response.statusCode ?? 0;
        if (status >= 400) _onFailed();
      },
      shouldOverrideUrlLoading: (_, action) async {
        if (action.isForMainFrame == false) {
          return NavigationActionPolicy.ALLOW;
        }
        final host = action.request.url?.host;
        // 站外主框架导航一律拒绝：本页不是通用浏览器。
        return host == _allowedHost
            ? NavigationActionPolicy.ALLOW
            : NavigationActionPolicy.CANCEL;
      },
    );
  }
}

class _PrivacyErrorView extends StatelessWidget {
  const _PrivacyErrorView({
    required this.url,
    required this.onRetry,
    required this.onCopyLink,
  });

  final String url;
  final VoidCallback onRetry;
  final VoidCallback onCopyLink;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 48, color: scheme.outline),
            const SizedBox(height: 16),
            Text(
              l10n.privacyLoadFailedTitle,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.privacyLoadFailedBody(url),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.tonalIcon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: Text(l10n.commonRetry),
                ),
                TextButton.icon(
                  onPressed: onCopyLink,
                  icon: const Icon(Icons.link_outlined, size: 18),
                  label: Text(l10n.commonCopyLink),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
