/// i18n 底座的守门测试：文案表齐全、映射无漏。
///
/// 「全部显示字段可统一配置」靠三条不变量兜住：
/// 1. 各语言 arb 的键集合完全一致（缺译 = 运行时回落到模板语言，用户看到夹生页面）；
/// 2. 每个 [SeedPalette] 预设都有显示名（漏了会把内部 id 露到 UI）；
/// 3. 每门受支持语言都有母语名（漏了语言选择器会显示 `zh` / `en` 这种裸标签）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/ui/i18n/locale_options.dart';
import 'package:elecon/ui/settings/appearance_section.dart';
import 'package:elecon/ui/theme/theme_prefs.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// arb 的消息键（剔除 `@@locale` 等元数据与 `@key` 描述块）。
Set<String> _messageKeys(File file) {
  final map = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  return map.keys.where((k) => !k.startsWith('@')).toSet();
}

void main() {
  final l10nDir = Directory('lib/l10n');

  test('每门语言的 arb 键集合一致', () {
    final arbs = l10nDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.arb'))
        .toList();
    expect(arbs.length, greaterThanOrEqualTo(2), reason: '至少 zh + en');

    final template = arbs.firstWhere((f) => f.path.endsWith('app_zh.arb'));
    final expected = _messageKeys(template);
    for (final arb in arbs) {
      final keys = _messageKeys(arb);
      expect(
        keys.difference(expected),
        isEmpty,
        reason: '${arb.path} 有模板（app_zh.arb）里没有的键',
      );
      expect(
        expected.difference(keys),
        isEmpty,
        reason: '${arb.path} 缺少键（会回落到中文，页面夹生）',
      );
    }
  });

  test('arb 文件集 == AppLocalizations.supportedLocales', () {
    final tags = l10nDir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((name) => name.endsWith('.arb'))
        .map((name) => name.replaceAll(RegExp(r'^app_|\.arb$'), ''))
        .toSet();
    expect(
      AppLocalizations.supportedLocales.map((l) => l.languageCode).toSet(),
      tags,
    );
  });

  group('映射完整性', () {
    for (final locale in AppLocalizations.supportedLocales) {
      test('${locale.languageCode}：主题色与语言名均有显示文案', () async {
        final l10n = await AppLocalizations.delegate.load(locale);

        for (final palette in SeedPalette.presets) {
          final label = seedPaletteLabel(l10n, palette.id);
          expect(
            label,
            isNot(palette.id),
            reason: '主题色 ${palette.id} 缺显示名（会把内部 id 露到 UI）',
          );
          expect(label, isNotEmpty);
        }

        for (final tag in appLocaleTags()) {
          final label = appLocaleLabel(l10n, tag);
          expect(label, isNotEmpty);
          expect(label, isNot(tag), reason: '语言 $tag 缺母语名');
        }
      });
    }
  });

  group('语言偏好解析', () {
    test('null / 未知标签都按跟随系统处理', () {
      expect(resolveAppLocale(null), isNull);
      expect(resolveAppLocale('klingon'), isNull);
    });

    test('受支持标签解析为对应 Locale', () {
      expect(resolveAppLocale('zh'), const Locale('zh'));
      expect(resolveAppLocale('en'), const Locale('en'));
    });

    test('选项顺序：跟随系统在前', () {
      expect(appLocaleTags().first, kSystemLocaleTag);
      expect(
        appLocaleTags().length,
        AppLocalizations.supportedLocales.length + 1,
      );
    });
  });

  group('ThemePrefs.localeTag', () {
    test('默认跟随系统，落盘时不写键', () {
      expect(ThemePrefs.defaults.localeTag, isNull);
      expect(ThemePrefs.defaults.toJson().containsKey('localeTag'), isFalse);
    });

    test('round-trip 保留标签', () {
      const prefs = ThemePrefs(localeTag: 'en');
      expect(ThemePrefs.fromJson(prefs.toJson()).localeTag, 'en');
    });

    test('copyWith：不传保持、传 null 改回跟随系统', () {
      const prefs = ThemePrefs(localeTag: 'en');
      expect(prefs.copyWith(seedId: 'teal').localeTag, 'en');
      expect(prefs.copyWith(localeTag: null).localeTag, isNull);
    });

    test('空串等脏值回落到跟随系统', () {
      expect(ThemePrefs.fromJson({'localeTag': ''}).localeTag, isNull);
    });
  });
}
