/// 设置页「外观」与「无障碍」区块。
library;

import 'package:flutter/material.dart';

import '../theme/theme_prefs.dart';
import '../theme/theme_scope.dart';

class AppearanceSection extends StatelessWidget {
  const AppearanceSection({super.key});

  @override
  Widget build(BuildContext context) {
    final themeCtrl = ThemeScope.of(context);
    final prefs = themeCtrl.prefs;
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle(title: '外观'),
        Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const ListTile(
                leading: Icon(Icons.palette_outlined),
                title: Text('主题色'),
                subtitle: Text('影响主色与界面强调色'),
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
                        selected: prefs.seedId == p.id,
                        onTap: () => themeCtrl.setSeedId(p.id),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.brightness_6_outlined),
                title: const Text('深色模式'),
                subtitle: Text(_themeModeLabel(prefs.themeMode)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: SegmentedButton<ThemeMode>(
                  segments: const [
                    ButtonSegment(
                      value: ThemeMode.system,
                      label: Text('系统'),
                      icon: Icon(Icons.brightness_auto, size: 18),
                    ),
                    ButtonSegment(
                      value: ThemeMode.light,
                      label: Text('浅色'),
                      icon: Icon(Icons.light_mode_outlined, size: 18),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      label: Text('深色'),
                      icon: Icon(Icons.dark_mode_outlined, size: 18),
                    ),
                  ],
                  selected: {prefs.themeMode},
                  onSelectionChanged: (set) {
                    if (set.isEmpty) return;
                    themeCtrl.setThemeMode(set.first);
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const _SectionTitle(title: '无障碍'),
        Card(
          child: SwitchListTile(
            secondary: Icon(
              Icons.contrast,
              color: prefs.highContrast ? scheme.primary : null,
            ),
            title: const Text('高对比模式'),
            subtitle: const Text('提高文字与控件对比度，覆盖全部主题外观'),
            value: prefs.highContrast,
            onChanged: themeCtrl.setHighContrast,
          ),
        ),
        const SizedBox(height: 16),
        const _SectionTitle(title: '实验性'),
        Card(
          child: SwitchListTile(
            secondary: Icon(
              Icons.water_drop_outlined,
              color: prefs.effectiveLiquidGlass ? scheme.primary : null,
            ),
            title: const Text('液态玻璃'),
            subtitle: Text(
              prefs.highContrast
                  ? '高对比模式下已自动关闭（半透明会降低对比度）'
                  : '导航栏与卡片半透明毛玻璃效果，可能影响性能',
            ),
            value: prefs.liquidGlass,
            onChanged: prefs.highContrast ? null : themeCtrl.setLiquidGlass,
          ),
        ),
      ],
    );
  }

  static String _themeModeLabel(ThemeMode mode) => switch (mode) {
        ThemeMode.system => '跟随系统',
        ThemeMode.light => '始终浅色',
        ThemeMode.dark => '始终深色',
      };
}

class _SeedSwatch extends StatelessWidget {
  const _SeedSwatch({
    required this.palette,
    required this.selected,
    required this.onTap,
  });

  final SeedPalette palette;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: palette.label,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
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
                  color: ThemeData.estimateBrightnessForColor(palette.seed) ==
                          Brightness.dark
                      ? Colors.white
                      : Colors.black,
                )
              : null,
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
