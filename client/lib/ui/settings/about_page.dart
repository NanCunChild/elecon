/// Settings → 关于页：图标 / 名称 + 版本 / 本轮大版本箴言 / 条款入口。
///
/// 版式自上而下：应用图标（当前为占位）→ 名称与版本副标题 → 居中箴言 → 条款卡片。
/// 屏幕够高时箴言吃掉中部留白居中显示，屏幕矮时整页可滚动（不裁切）。
///
/// 显示文案全部取自 l10n（含箴言本身），不可翻译的事实（版本号、链接）取自
/// [app_info.dart](../../app_info.dart)。
library;

import 'package:flutter/material.dart';

import '../../app_info.dart';
import '../../l10n/gen/app_localizations.dart';
import '../theme/liquid_glass.dart';
import 'privacy_policy_page.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key, this.version = kAppVersion});

  /// 展示用版本号；默认取构建期注入的 [kAppVersion]（测试可固定）。
  final String version;

  void _openPrivacy(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const PrivacyPolicyPage()),
    );
  }

  void _openLicenses(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Flutter 内建许可页：逐条列出依赖的 LICENSE 原文（红线 #9 的用户侧披露）。
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LicensePage(
          applicationName: l10n.appName,
          applicationVersion: l10n.aboutVersion(version),
          applicationIcon: const Padding(
            padding: EdgeInsets.only(top: 12),
            child: _AppIconPlaceholder(size: 72),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bottomPadding = liquidGlassEnabled(context) ? 100.0 : 24.0;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.aboutTitle)),
      body: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(16, 24, 16, bottomPadding),
            child: ConstrainedBox(
              // 内容不足一屏时撑满，让 Spacer 生效把箴言压到中部。
              constraints: BoxConstraints(
                minHeight: constraints.maxHeight - 24 - bottomPadding,
              ),
              // 三段式：头部 / 箴言 / 条款。spaceBetween 把多出的高度分给段间，
              // 使箴言落在中部；内容超一屏时退化为普通顺排并整页滚动。
              // （不用 Spacer：滚动视图里 Column 的主轴上界无穷，flex 子节点会报错。）
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Center(child: _AppIconPlaceholder(size: 96)),
                      const SizedBox(height: 20),
                      Text(
                        l10n.appName,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        l10n.aboutVersion(version),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 40),
                    child: _VersionEpigraph(
                      quote: l10n.aboutQuote,
                      source: l10n.aboutQuoteSource,
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _SectionTitle(title: l10n.aboutSectionLegal),
                      LiquidGlassSurface(
                        child: Column(
                          children: [
                            ListTile(
                              leading: const Icon(Icons.privacy_tip_outlined),
                              title: Text(l10n.aboutPrivacyTile),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => _openPrivacy(context),
                            ),
                            const Divider(height: 1),
                            ListTile(
                              leading:
                                  const Icon(Icons.workspace_premium_outlined),
                              title: Text(l10n.aboutOpenSourceLicenses),
                              subtitle:
                                  Text(l10n.aboutOpenSourceLicensesSubtitle),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => _openLicenses(context),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 应用图标占位：正式图标资源落地后，把这里换成 `Image.asset`（并同步
/// [AppLocalizations.aboutIconSemanticLabel] 去掉「占位」字样）。
///
/// 形状 / 配色走主题 token（含高对比主题），不硬编码颜色。
class _AppIconPlaceholder extends StatelessWidget {
  const _AppIconPlaceholder({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: AppLocalizations.of(context).aboutIconSemanticLabel,
      image: true,
      child: Container(
        width: size,
        height: size,
        decoration: ShapeDecoration(
          color: scheme.primaryContainer,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(size * 0.26),
          ),
        ),
        child: Center(
          child: Icon(
            Icons.hub_outlined,
            size: size * 0.5,
            color: scheme.onPrimaryContainer,
          ),
        ),
      ),
    );
  }
}

/// 本轮大版本箴言：居中引文 + 出处标签。
class _VersionEpigraph extends StatelessWidget {
  const _VersionEpigraph({required this.quote, required this.source});

  final String quote;
  final String source;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      children: [
        Icon(Icons.format_quote, size: 28, color: scheme.primary),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(
            quote,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontStyle: FontStyle.italic,
              height: 1.5,
              color: scheme.onSurface,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '— $source',
          textAlign: TextAlign.center,
          style: theme.textTheme.labelMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
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
