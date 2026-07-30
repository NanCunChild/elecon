/// 语言选项：把落盘的语言标签（[ThemePrefs.localeTag]）与 gen_l10n 的
/// [AppLocalizations.supportedLocales] 对上。
///
/// 语言清单的**唯一来源是 `lib/l10n/*.arb` 文件集**——新增一门语言 = 新增一个 arb
/// + 在 [appLocaleLabel] 补一条母语名，别处不再有第二份清单。
library;

import 'package:flutter/widgets.dart';

import '../../l10n/gen/app_localizations.dart';

/// 「跟随系统」在偏好里表示为 `null` 标签。
const String? kSystemLocaleTag = null;

/// 语言选择器的选项顺序：跟随系统在前，随后按 arb 的声明顺序。
List<String?> appLocaleTags() => <String?>[
      kSystemLocaleTag,
      for (final locale in AppLocalizations.supportedLocales)
        locale.languageCode,
    ];

/// 落盘标签 → [Locale]。未知/不再受支持的标签按「跟随系统」处理（返回 `null`），
/// 使删除某个 arb 后旧偏好不会把 UI 卡在缺失语言上。
Locale? resolveAppLocale(String? tag) {
  if (tag == null) return null;
  for (final locale in AppLocalizations.supportedLocales) {
    if (locale.languageCode == tag) return locale;
  }
  return null;
}

/// 选项显示名。语言名按**母语**书写（endonym），故各语言的 arb 里取值相同。
String appLocaleLabel(AppLocalizations l10n, String? tag) => switch (tag) {
      kSystemLocaleTag => l10n.appearanceLanguageSystem,
      'zh' => l10n.appearanceLanguageZh,
      'en' => l10n.appearanceLanguageEn,
      // 新增 arb 未补母语名时退化为标签本身（不崩、但测试会抓到，见
      // test/locale_options_test.dart）。
      _ => tag!,
    };
