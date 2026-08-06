import 'dart:io';

import 'package:elecon/l10n/gen/app_localizations.dart';
import 'package:elecon/main_apple.dart' as apple_entry;
import 'package:elecon/ui/settings/appearance_section.dart';
import 'package:elecon/ui/theme/app_theme.dart';
import 'package:elecon/ui/theme/liquid_glass.dart';
import 'package:elecon/ui/theme/liquid_glass_apple.dart';
import 'package:elecon/ui/theme/theme_controller.dart';
import 'package:elecon/ui/theme/theme_prefs.dart';
import 'package:elecon/ui/theme/theme_scope.dart';
import 'package:elecon/ui/theme/theme_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryThemeStore extends ThemeStore {
  _MemoryThemeStore() : super(supportDirProvider: () => Directory.systemTemp);

  @override
  Future<ThemePrefs> load() async => ThemePrefs.defaults;

  @override
  Future<void> save(ThemePrefs prefs) async {}
}

void main() {
  setUp(configureAppleLiquidGlass);

  test('Apple compile entry point is linked', () {
    expect(apple_entry.main, isNotNull);
  });

  test('Apple implementation enables theme and glass settings', () {
    final theme = AppTheme.light(const ThemePrefs(liquidGlass: true));
    expect(theme.extension<LiquidGlassTokens>()!.enabled, isTrue);

    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xffe11d48),
      brightness: Brightness.light,
    );
    final surface = liquidGlassSurfaceSettings(scheme);
    final bar = liquidGlassBarSettings(scheme);
    final indicator = liquidGlassIndicatorSettings(scheme);
    expect(surface.glassColor.a, lessThan(bar.glassColor.a));
    expect(bar.glassColor.a, lessThanOrEqualTo(indicator.glassColor.a));
  });

  testWidgets('Apple implementation exposes the liquid-glass switch', (
    tester,
  ) async {
    final controller = ThemeController(store: _MemoryThemeStore());
    await controller.load();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.light(controller.prefs),
        home: ThemeScope(
          controller: controller,
          child: const Scaffold(body: AppearanceSection()),
        ),
      ),
    );
    final zh = await AppLocalizations.delegate.load(const Locale('zh'));

    expect(find.text(zh.experimentalSection), findsOneWidget);
    expect(find.text(zh.experimentalLiquidGlassTitle), findsOneWidget);
  });
}
