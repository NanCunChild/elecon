/// 设置页「外观」「无障碍」「实验性」区块（含语言选择）。
///
/// 显示文案一律取 [AppLocalizations]（`lib/l10n/*.arb`），不在此写字面量：
/// 主题色名按 [SeedPalette.id] → l10n 键映射，语言名走 `ui/i18n/locale_options.dart`。
library;

import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../i18n/locale_options.dart';
import '../theme/liquid_glass.dart';
import '../theme/theme_prefs.dart';
import '../theme/theme_scope.dart';

class AppearanceSection extends StatelessWidget {
  const AppearanceSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final themeCtrl = ThemeScope.of(context);
    final prefs = themeCtrl.prefs;
    final scheme = Theme.of(context).colorScheme;
    final liquidGlassTile = buildLiquidGlassSettingsTile(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(title: l10n.appearanceSection),
        LiquidGlassSurface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _PreferenceMenu<String>(
                menuKey: const ValueKey('appearance-seed-menu'),
                icon: Icons.palette_outlined,
                title: l10n.appearanceSeedTitle,
                value: prefs.seedId,
                label: seedPaletteLabel(l10n, prefs.seedId),
                valueIcon: _ColorDot(color: prefs.seedColor),
                items: [
                  for (final palette in SeedPalette.presets)
                    PopupMenuItem(
                      value: palette.id,
                      child: Row(
                        children: [
                          _ColorDot(color: palette.seed),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(seedPaletteLabel(l10n, palette.id)),
                          ),
                          if (prefs.seedId == palette.id)
                            const Icon(Icons.check, size: 20),
                        ],
                      ),
                    ),
                ],
                onSelected: themeCtrl.setSeedId,
              ),
              const Divider(height: 1),
              _PreferenceMenu<ThemeMode>(
                menuKey: const ValueKey('appearance-mode-menu'),
                icon: Icons.brightness_6_outlined,
                title: l10n.appearanceThemeModeTitle,
                value: prefs.themeMode,
                label: switch (prefs.themeMode) {
                  ThemeMode.system => l10n.appearanceThemeModeSystem,
                  ThemeMode.light => l10n.appearanceThemeModeLight,
                  ThemeMode.dark => l10n.appearanceThemeModeDark,
                },
                items: [
                  for (final mode in ThemeMode.values)
                    CheckedPopupMenuItem(
                      value: mode,
                      checked: prefs.themeMode == mode,
                      child: Text(_themeModeLabel(l10n, mode)),
                    ),
                ],
                onSelected: themeCtrl.setThemeMode,
              ),
              const Divider(height: 1),
              // A non-null menu value distinguishes system selection from dismissal.
              _PreferenceMenu<String>(
                menuKey: const ValueKey('appearance-language-menu'),
                icon: Icons.translate_outlined,
                title: l10n.appearanceLanguageTitle,
                value: resolveAppLocale(prefs.localeTag) == null
                    ? 'system'
                    : prefs.localeTag!,
                label: appLocaleLabel(
                  l10n,
                  resolveAppLocale(prefs.localeTag) == null
                      ? null
                      : prefs.localeTag,
                ),
                items: [
                  for (final tag in appLocaleTags())
                    CheckedPopupMenuItem(
                      value: tag ?? 'system',
                      checked:
                          resolveAppLocale(prefs.localeTag)?.languageCode ==
                          tag,
                      child: Text(appLocaleLabel(l10n, tag)),
                    ),
                ],
                onSelected: (tag) =>
                    themeCtrl.setLocaleTag(tag == 'system' ? null : tag),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SectionTitle(title: l10n.accessibilitySection),
        LiquidGlassSurface(
          child: SwitchListTile(
            secondary: Icon(
              Icons.contrast,
              color: prefs.highContrast ? scheme.primary : null,
            ),
            title: Text(l10n.accessibilityHighContrastTitle),
            subtitle: Text(l10n.accessibilityHighContrastSubtitle),
            value: prefs.highContrast,
            onChanged: themeCtrl.setHighContrast,
          ),
        ),
        if (liquidGlassTile != null) ...[
          const SizedBox(height: 16),
          _SectionTitle(title: l10n.experimentalSection),
          LiquidGlassSurface(child: liquidGlassTile),
        ],
      ],
    );
  }

  static String _themeModeLabel(AppLocalizations l10n, ThemeMode mode) =>
      switch (mode) {
        ThemeMode.system => l10n.appearanceThemeModeSystemDetail,
        ThemeMode.light => l10n.appearanceThemeModeLightDetail,
        ThemeMode.dark => l10n.appearanceThemeModeDarkDetail,
      };
}

/// [SeedPalette.id] → 显示名。新增预设色 = 加 id + 在两份 arb 补键 + 补一条 case
///（漏了会退化为 id 本身，由 `test/appearance_l10n_test.dart` 抓）。
String seedPaletteLabel(AppLocalizations l10n, String id) => switch (id) {
  'blue' => l10n.appearanceSeedBlue,
  'indigo' => l10n.appearanceSeedIndigo,
  'teal' => l10n.appearanceSeedTeal,
  'green' => l10n.appearanceSeedGreen,
  'amber' => l10n.appearanceSeedAmber,
  'orange' => l10n.appearanceSeedOrange,
  'rose' => l10n.appearanceSeedRose,
  'violet' => l10n.appearanceSeedViolet,
  _ => id,
};

class _PreferenceMenu<T> extends StatelessWidget {
  const _PreferenceMenu({
    required this.menuKey,
    required this.icon,
    required this.title,
    required this.value,
    required this.label,
    required this.items,
    required this.onSelected,
    this.valueIcon,
  });

  final Key menuKey;
  final IconData icon;
  final String title, label;
  final T value;
  final List<PopupMenuEntry<T>> items;
  final ValueChanged<T> onSelected;
  final Widget? valueIcon;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    child: Row(
      children: [
        Icon(icon),
        const SizedBox(width: 12),
        Expanded(child: Text(title)),
        const SizedBox(width: 8),
        Flexible(
          fit: FlexFit.tight,
          child: Align(
            alignment: Alignment.centerRight,
            child: PopupMenuButton<T>(
              key: menuKey,
              tooltip: '$title: $label',
              initialValue: value,
              itemBuilder: (_) => items,
              onSelected: onSelected,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (valueIcon != null) ...[
                      valueIcon!,
                      const SizedBox(width: 8),
                    ],
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Icon(Icons.arrow_drop_down),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 20,
    height: 20,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
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
