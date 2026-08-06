import 'dart:io';

import 'package:elecon/ui/theme/app_theme.dart';
import 'package:elecon/ui/theme/liquid_glass.dart';
import 'package:elecon/ui/theme/theme_controller.dart';
import 'package:elecon/ui/theme/theme_prefs.dart';
import 'package:elecon/ui/theme/theme_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ThemePrefs', () {
    test('defaults and round-trip json', () {
      const prefs = ThemePrefs(
        seedId: 'teal',
        themeMode: ThemeMode.dark,
        highContrast: true,
        liquidGlass: true,
      );
      final restored = ThemePrefs.fromJson(prefs.toJson());
      expect(restored, prefs);
      // 高对比强制关闭液态玻璃生效。
      expect(restored.effectiveLiquidGlass, isFalse);
    });

    test('unknown seed falls back to first preset', () {
      final prefs = ThemePrefs.fromJson({'seedId': 'not-a-color'});
      expect(prefs.seedId, SeedPalette.presets.first.id);
    });

    test('effectiveLiquidGlass requires both flags', () {
      expect(
        const ThemePrefs(
          liquidGlass: true,
          highContrast: false,
        ).effectiveLiquidGlass,
        isTrue,
      );
      expect(
        const ThemePrefs(
          liquidGlass: true,
          highContrast: true,
        ).effectiveLiquidGlass,
        isFalse,
      );
    });
  });

  group('AppTheme', () {
    test('high contrast overrides surfaces to pure black/white', () {
      const prefs = ThemePrefs(highContrast: true);
      final light = AppTheme.light(prefs);
      final dark = AppTheme.dark(prefs);
      expect(light.colorScheme.surface, Colors.white);
      expect(light.colorScheme.onSurface, Colors.black);
      expect(dark.colorScheme.surface, Colors.black);
      expect(dark.colorScheme.onSurface, Colors.white);
      expect(light.colorScheme.surfaceTint, Colors.transparent);
    });

    test('liquid glass stays disabled without Apple implementation', () {
      final on = AppTheme.light(
        const ThemePrefs(liquidGlass: true, highContrast: false),
      );
      final off = AppTheme.light(
        const ThemePrefs(liquidGlass: true, highContrast: true),
      );
      expect(on.extension<LiquidGlassTokens>()!.enabled, isFalse);
      expect(off.extension<LiquidGlassTokens>()!.enabled, isFalse);
    });

    test('seed changes primary hue family', () {
      final blue = AppTheme.light(const ThemePrefs(seedId: 'blue'));
      final rose = AppTheme.light(const ThemePrefs(seedId: 'rose'));
      expect(blue.colorScheme.primary, isNot(equals(rose.colorScheme.primary)));
    });

    test('liquid glass preference does not tint unsupported platforms', () {
      final glassOn = AppTheme.light(
        const ThemePrefs(seedId: 'rose', liquidGlass: true),
      );
      final glassOff = AppTheme.light(
        const ThemePrefs(seedId: 'rose', liquidGlass: false),
      );
      expect(
        glassOn.scaffoldBackgroundColor,
        equals(glassOff.scaffoldBackgroundColor),
      );
      expect(
        glassOn.scaffoldBackgroundColor,
        equals(glassOn.colorScheme.surface),
      );
    });
  });

  group('ThemeStore / ThemeController', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('elecon_theme_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('store persists and reloads', () async {
      final store = ThemeStore(supportDirProvider: () => tempDir);
      const prefs = ThemePrefs(
        seedId: 'violet',
        themeMode: ThemeMode.light,
        highContrast: true,
      );
      await store.save(prefs);
      final loaded = await store.load();
      expect(loaded, prefs);
    });

    test('controller load + set notifies', () async {
      final store = ThemeStore(supportDirProvider: () => tempDir);
      final ctrl = ThemeController(store: store);
      var ticks = 0;
      ctrl.addListener(() => ticks++);

      await ctrl.load();
      expect(ctrl.isLoaded, isTrue);
      expect(ticks, 1);

      await ctrl.setSeedId('amber');
      expect(ctrl.seedId, 'amber');
      expect(ticks, 2);

      await ctrl.setThemeMode(ThemeMode.dark);
      await ctrl.setHighContrast(true);
      await ctrl.setLiquidGlass(true);
      expect(ctrl.prefs.themeMode, ThemeMode.dark);
      expect(ctrl.highContrast, isTrue);
      expect(ctrl.liquidGlass, isTrue);
      expect(ctrl.effectiveLiquidGlass, isFalse);

      final reloaded = ThemeController(store: store);
      await reloaded.load();
      expect(reloaded.prefs, ctrl.prefs);
    });

    test('locale tag persists and can go back to system', () async {
      final store = ThemeStore(supportDirProvider: () => tempDir);
      final ctrl = ThemeController(store: store);
      await ctrl.load();
      expect(ctrl.localeTag, isNull, reason: '默认跟随系统');

      await ctrl.setLocaleTag('en');
      final reloaded = ThemeController(store: store);
      await reloaded.load();
      expect(reloaded.localeTag, 'en');

      await ctrl.setLocaleTag(null);
      final backToSystem = ThemeController(store: store);
      await backToSystem.load();
      expect(backToSystem.localeTag, isNull);
    });
  });
}
