/// 设置页——登录、账号、调试选项。
library;

import 'package:flutter/material.dart';

import '../../core/broker/inject_policy.dart';
import '../../core/credential/secure_store.dart';
import '../../core/credential/store.dart';
import '../../core/login/webview_login.dart';
import '../login/webview_login_page.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  Future<void> _openWebViewLogin(BuildContext context) async {
    final store = CredentialStore(
      store: InMemorySecureStore(releaseMode: false),
    );
    const login = LoginManifestView(
      schoolId: 'xidian',
      url: 'https://ids.xidian.edu.cn/authserver/login?service=https://ehall.xidian.edu.cn/new/index.html',
      navigationAllow: const [
        'https://ids.xidian.edu.cn/*',
        'https://ehall.xidian.edu.cn/*',
        'https://v8scan.xidian.edu.cn/*',
        'https://hyytsgxzs.xidian.edu.cn/*',
        'https://xxcapp.xidian.edu.cn/*',
      ],
      successUrlMatches: const [
        'https://ehall.xidian.edu.cn/new/index.html*',
        'https://v8scan.xidian.edu.cn/myaccount/openMyAccount*',
        'https://hyytsgxzs.xidian.edu.cn/*',
      ],
      brokerView: const BrokerManifestView(
        allow: [
          'https://ehall.xidian.edu.cn/*',
          'https://v8scan.xidian.edu.cn/*',
          'https://hyytsgxzs.xidian.edu.cn/*',
        ],
        credentials: {
          'ehall-session': CredentialDecl(
            scope: ['https://ehall.xidian.edu.cn/*'],
            type: 'cookie',
          ),
          'card-session': CredentialDecl(
            scope: ['https://v8scan.xidian.edu.cn/*'],
            type: 'cookie',
          ),
          'library-session': CredentialDecl(
            scope: ['https://hyytsgxzs.xidian.edu.cn/*'],
            type: 'cookie',
          ),
        },
      ),
    );

    if (!context.mounted) return;
    final result = await Navigator.of(context).push<WebViewLoginResult>(
      MaterialPageRoute(
        builder: (_) => WebViewLoginPage(
          login: login,
          store: store,
          debugLog: true,
          tlsProceedHosts: const {
            'ids.xidian.edu.cn',
            'ehall.xidian.edu.cn',
          },
        ),
      ),
    );

    if (!context.mounted) return;
    final msg = switch (result?.status) {
      WebViewLoginStatus.success => '登录成功！已收割 ${store.list().length} 条凭证',
      WebViewLoginStatus.cancelled => '已取消',
      WebViewLoginStatus.error => '登录失败：${result?.error ?? "未知错误"}',
      null => '未知结果',
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _SectionTitle(title: '账户'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.school),
              title: const Text('西安电子科技大学'),
              subtitle: const Text('XIDIAN · IDS CAS 登录'),
              trailing: FilledButton.tonal(
                onPressed: () => _openWebViewLogin(context),
                child: const Text('登录'),
              ),
            ),
          ),
          const SizedBox(height: 16),
          _SectionTitle(title: '调试'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.bug_report_outlined),
                  title: const Text('WebView 日志面板'),
                  subtitle: const Text('登录时默认开启'),
                  value: true,
                  onChanged: (_) {},
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SectionTitle(title: '关于'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('elecon'),
                  subtitle: const Text('校园信息聚合平台'),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.code),
                  title: const Text('版本'),
                  subtitle: const Text('0.1.0-dev'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 0, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}
