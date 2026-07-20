/// 外观偏好控制器：加载/保存/变更通知。
library;

import 'package:flutter/material.dart';

import 'theme_prefs.dart';
import 'theme_store.dart';

class ThemeController extends ChangeNotifier {
  ThemeController({ThemeStore? store}) : _store = store ?? ThemeStore();

  final ThemeStore _store;
  ThemePrefs _prefs = ThemePrefs.defaults;
  var _loaded = false;

  ThemePrefs get prefs => _prefs;
  bool get isLoaded => _loaded;
  ThemeMode get themeMode => _prefs.themeMode;
  bool get highContrast => _prefs.highContrast;
  bool get liquidGlass => _prefs.liquidGlass;
  bool get effectiveLiquidGlass => _prefs.effectiveLiquidGlass;
  Color get seedColor => _prefs.seedColor;
  String get seedId => _prefs.seedId;

  Future<void> load() async {
    _prefs = await _store.load();
    _loaded = true;
    notifyListeners();
  }

  Future<void> _commit(ThemePrefs next) async {
    if (next == _prefs) return;
    _prefs = next;
    notifyListeners();
    await _store.save(next);
  }

  Future<void> setSeedId(String id) =>
      _commit(_prefs.copyWith(seedId: SeedPalette.byId(id).id));

  Future<void> setThemeMode(ThemeMode mode) =>
      _commit(_prefs.copyWith(themeMode: mode));

  Future<void> setHighContrast(bool enabled) =>
      _commit(_prefs.copyWith(highContrast: enabled));

  Future<void> setLiquidGlass(bool enabled) =>
      _commit(_prefs.copyWith(liquidGlass: enabled));
}
