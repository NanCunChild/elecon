/// 关于页 / 隐私政策页的渲染与 l10n 接线。
///
/// 关键回归点：版式三段（图标 → 名称+版本 → 箴言 → 条款）齐备，且切换 locale 时
/// 文案随之切换（说明页面未夹带硬编码字面量）。
///
/// 隐私政策页只验证骨架：widget 测试环境没有 WebView 平台实现，内嵌浏览器本体经
/// [PrivacyPolicyPage.viewerBuilder] 替换掉。
library;

import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/ui/settings/about_page.dart';
import 'package:elecon/ui/settings/privacy_policy_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child, {Locale locale = const Locale('zh')}) {
  return MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: ThemeData(useMaterial3: true),
    home: child,
  );
}

void main() {
  group('AboutPage', () {
    testWidgets('renders icon placeholder, name+version, quote and legal tiles',
        (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_wrap(const AboutPage(version: '9.9.9-test')));
      await tester.pumpAndSettle();

      final zh = await AppLocalizations.delegate.load(const Locale('zh'));

      // 图标占位（正式资源落地后此断言改为查 Image）。
      expect(find.bySemanticsLabel(zh.aboutIconSemanticLabel), findsOneWidget);
      // 名称 + 版本副标题。
      expect(find.text(zh.appName), findsOneWidget);
      expect(find.text(zh.aboutVersion('9.9.9-test')), findsOneWidget);
      // 本轮大版本箴言 + 出处。
      expect(find.text(zh.aboutQuote), findsOneWidget);
      expect(find.text('— ${zh.aboutQuoteSource}'), findsOneWidget);
      // 条款入口可点。
      expect(find.text(zh.aboutOpenSourceLicenses), findsOneWidget);
      final privacyTile = tester.widget<ListTile>(
        find.ancestor(
          of: find.text(zh.aboutPrivacyTile),
          matching: find.byType(ListTile),
        ),
      );
      expect(privacyTile.onTap, isNotNull);

      semantics.dispose();
    });

    testWidgets('follows locale (no hardcoded literals)', (tester) async {
      await tester.pumpWidget(
        _wrap(const AboutPage(version: '9.9.9'), locale: const Locale('en')),
      );
      await tester.pumpAndSettle();

      final en = await AppLocalizations.delegate.load(const Locale('en'));
      final zh = await AppLocalizations.delegate.load(const Locale('zh'));

      expect(find.text(en.aboutVersion('9.9.9')), findsOneWidget);
      expect(find.text(en.aboutPrivacyTile), findsOneWidget);
      expect(find.text(zh.aboutPrivacyTile), findsNothing);
    });
  });

  group('PrivacyPolicyPage', () {
    testWidgets('renders title, placeholder notice and copy-link action',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          PrivacyPolicyPage(
            url: 'https://example.invalid/privacy',
            viewerBuilder: (_) => const SizedBox.shrink(),
          ),
        ),
      );
      // 加载态的进度条是无限动画，不能 pumpAndSettle。
      await tester.pump();

      final zh = await AppLocalizations.delegate.load(const Locale('zh'));
      expect(find.text(zh.privacyTitle), findsOneWidget);
      expect(find.text(zh.privacyPlaceholderNotice), findsOneWidget);
      expect(find.byTooltip(zh.commonCopyLink), findsOneWidget);
      // loading 态：进度条在位，错误态文案不在。
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text(zh.privacyLoadFailedTitle), findsNothing);
    });
  });
}
