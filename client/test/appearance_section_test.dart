/// 设置页外观区块：文案全部走 l10n，且语言选择器能改偏好。
library;

import 'dart:io';

import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/ui/settings/appearance_section.dart';
import 'package:elecon/ui/theme/theme_controller.dart';
import 'package:elecon/ui/theme/theme_prefs.dart';
import 'package:elecon/ui/theme/theme_scope.dart';
import 'package:elecon/ui/theme/theme_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 内存版偏好落盘：testWidgets 的 fake-async 区里真实文件 IO 的 Future 不会完成，
/// 故不落磁盘（落盘本体由 theme_prefs_test 的 ThemeStore 用例覆盖）。
class _MemoryThemeStore extends ThemeStore {
  _MemoryThemeStore() : super(supportDirProvider: () => Directory.systemTemp);

  ThemePrefs? saved;

  @override
  Future<ThemePrefs> load() async => saved ?? ThemePrefs.defaults;

  @override
  Future<void> save(ThemePrefs prefs) async => saved = prefs;
}

void main() {
  Future<(ThemeController, _MemoryThemeStore)> pumpSection(
    WidgetTester tester, {
    Locale locale = const Locale('zh'),
  }) async {
    final store = _MemoryThemeStore();
    final ctrl = ThemeController(store: store);
    await ctrl.load();
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(useMaterial3: true),
        home: ThemeScope(
          controller: ctrl,
          child: const Scaffold(
            body: SingleChildScrollView(child: AppearanceSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (ctrl, store);
  }

  testWidgets('区块标题与主题色名取自 l10n', (tester) async {
    await pumpSection(tester);
    final zh = await AppLocalizations.delegate.load(const Locale('zh'));

    expect(find.text(zh.appearanceSection), findsOneWidget);
    expect(find.text(zh.accessibilitySection), findsOneWidget);
    expect(find.text(zh.experimentalSection), findsNothing);
    expect(find.text(zh.experimentalLiquidGlassTitle), findsNothing);
    expect(find.text(zh.appearanceLanguageTitle), findsOneWidget);
    // 主题色名走 tooltip / semantics，不把内部 id 露出来。
    expect(find.byTooltip(zh.appearanceSeedBlue), findsOneWidget);
    expect(find.byTooltip('blue'), findsNothing);
  });

  testWidgets('语言选择器写入偏好', (tester) async {
    final (ctrl, store) = await pumpSection(tester);
    final zh = await AppLocalizations.delegate.load(const Locale('zh'));
    expect(ctrl.localeTag, isNull, reason: '默认跟随系统');

    await tester.tap(find.byType(DropdownButton<String?>));
    await tester.pumpAndSettle();
    // 收起的选中项与展开的菜单项同文案，菜单项在后。
    await tester.tap(find.text(zh.appearanceLanguageEn).last);
    await tester.pumpAndSettle();

    expect(ctrl.localeTag, 'en');
    expect(store.saved?.localeTag, 'en', reason: '偏好已提交落盘');
  });

  testWidgets('en locale 下文案切换', (tester) async {
    await pumpSection(tester, locale: const Locale('en'));
    final en = await AppLocalizations.delegate.load(const Locale('en'));
    final zh = await AppLocalizations.delegate.load(const Locale('zh'));

    expect(find.text(en.appearanceSection), findsOneWidget);
    expect(find.text(zh.appearanceSection), findsNothing);
    expect(find.byTooltip(en.appearanceSeedBlue), findsOneWidget);
  });
}
