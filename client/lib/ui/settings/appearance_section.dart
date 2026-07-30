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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(title: l10n.appearanceSection),
        LiquidGlassSurface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                leading: const Icon(Icons.palette_outlined),
                title: Text(l10n.appearanceSeedTitle),
                subtitle: Text(l10n.appearanceSeedSubtitle),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final p in SeedPalette.presets)
                      _SeedSwatch(
                        palette: p,
                        label: seedPaletteLabel(l10n, p.id),
                        selected: prefs.seedId == p.id,
                        onTap: () => themeCtrl.setSeedId(p.id),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.brightness_6_outlined),
                title: Text(l10n.appearanceThemeModeTitle),
                subtitle: Text(_themeModeLabel(l10n, prefs.themeMode)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: SegmentedButton<ThemeMode>(
                  segments: [
                    ButtonSegment(
                      value: ThemeMode.system,
                      label: Text(l10n.appearanceThemeModeSystem),
                      icon: const Icon(Icons.brightness_auto, size: 18),
                    ),
                    ButtonSegment(
                      value: ThemeMode.light,
                      label: Text(l10n.appearanceThemeModeLight),
                      icon: const Icon(Icons.light_mode_outlined, size: 18),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      label: Text(l10n.appearanceThemeModeDark),
                      icon: const Icon(Icons.dark_mode_outlined, size: 18),
                    ),
                  ],
                  selected: {prefs.themeMode},
                  onSelectionChanged: (set) {
                    if (set.isEmpty) return;
                    themeCtrl.setThemeMode(set.first);
                  },
                ),
              ),
              const Divider(height: 1),
              // 语言：选项 = arb 文件集 + 跟随系统（见 locale_options.dart）。
              ListTile(
                leading: const Icon(Icons.translate_outlined),
                title: Text(l10n.appearanceLanguageTitle),
                subtitle: Text(appLocaleLabel(l10n, prefs.localeTag)),
                trailing: DropdownButton<String?>(
                  value: resolveAppLocale(prefs.localeTag) == null
                      // 未知/已失效的标签在 UI 上回落到「跟随系统」。
                      ? kSystemLocaleTag
                      : prefs.localeTag,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final tag in appLocaleTags())
                      DropdownMenuItem<String?>(
                        value: tag,
                        child: Text(appLocaleLabel(l10n, tag)),
                      ),
                  ],
                  onChanged: themeCtrl.setLocaleTag,
                ),
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
        const SizedBox(height: 16),
        _SectionTitle(title: l10n.experimentalSection),
        LiquidGlassSurface(
          child: SwitchListTile(
            secondary: Icon(
              Icons.water_drop_outlined,
              color: prefs.effectiveLiquidGlass ? scheme.primary : null,
            ),
            title: Text(l10n.experimentalLiquidGlassTitle),
            subtitle: Text(
              prefs.highContrast
                  ? l10n.experimentalLiquidGlassDisabledByContrast
                  : l10n.experimentalLiquidGlassSubtitle,
            ),
            value: prefs.liquidGlass,
            onChanged: prefs.highContrast ? null : themeCtrl.setLiquidGlass,
          ),
        ),
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

class _SeedSwatch extends StatelessWidget {
  const _SeedSwatch({
    required this.palette,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final SeedPalette palette;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Semantics(
          label: label,
          selected: selected,
          button: true,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: palette.seed,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? scheme.onSurface : scheme.outlineVariant,
                width: selected ? 3 : 1.5,
              ),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: palette.seed.withValues(alpha: 0.45),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : null,
            ),
            child: selected
                ? Icon(
                    Icons.check,
                    size: 20,
                    color:
                        ThemeData.estimateBrightnessForColor(palette.seed) ==
                                Brightness.dark
                            ? Colors.white
                            : Colors.black,
                  )
                : null,
          ),
        ),
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
