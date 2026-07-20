/// 外观偏好：主题色 / 明暗 / 无障碍高对比 / 实验性液态玻璃。
///
/// 高对比是无障碍开关，启用后覆盖全部主题的色面与对比策略，
/// 不是与浅色/深色并列的第三种主题模式。
library;

import 'package:flutter/material.dart';

/// 预设主题色（seed），UI 以色点展示。
class SeedPalette {
  const SeedPalette({
    required this.id,
    required this.label,
    required this.seed,
  });

  final String id;
  final String label;
  final Color seed;

  static const List<SeedPalette> presets = [
    SeedPalette(id: 'blue', label: '校园蓝', seed: Color(0xff3867d6)),
    SeedPalette(id: 'indigo', label: '靛蓝', seed: Color(0xff3f51b5)),
    SeedPalette(id: 'teal', label: '青绿', seed: Color(0xff0d9488)),
    SeedPalette(id: 'green', label: '叶绿', seed: Color(0xff2e7d32)),
    SeedPalette(id: 'amber', label: '琥珀', seed: Color(0xfff59e0b)),
    SeedPalette(id: 'orange', label: '橙', seed: Color(0xffea580c)),
    SeedPalette(id: 'rose', label: '玫红', seed: Color(0xffe11d48)),
    SeedPalette(id: 'violet', label: '紫', seed: Color(0xff7c3aed)),
  ];

  static SeedPalette byId(String? id) {
    for (final p in presets) {
      if (p.id == id) return p;
    }
    return presets.first;
  }

  static SeedPalette nearest(Color color) {
    SeedPalette best = presets.first;
    var bestDist = _dist(color, best.seed);
    for (final p in presets.skip(1)) {
      final d = _dist(color, p.seed);
      if (d < bestDist) {
        best = p;
        bestDist = d;
      }
    }
    return best;
  }

  static double _dist(Color a, Color b) {
    final dr = a.r - b.r;
    final dg = a.g - b.g;
    final db = a.b - b.b;
    return dr * dr + dg * dg + db * db;
  }
}

/// 可序列化的外观偏好。
class ThemePrefs {
  const ThemePrefs({
    this.seedId = 'blue',
    this.themeMode = ThemeMode.system,
    this.highContrast = false,
    this.liquidGlass = false,
  });

  final String seedId;
  final ThemeMode themeMode;
  final bool highContrast;
  final bool liquidGlass;

  static const ThemePrefs defaults = ThemePrefs();

  Color get seedColor => SeedPalette.byId(seedId).seed;

  /// 高对比启用时强制关闭液态玻璃视觉（玻璃半透明会降低对比度）。
  bool get effectiveLiquidGlass => liquidGlass && !highContrast;

  ThemePrefs copyWith({
    String? seedId,
    ThemeMode? themeMode,
    bool? highContrast,
    bool? liquidGlass,
  }) {
    return ThemePrefs(
      seedId: seedId ?? this.seedId,
      themeMode: themeMode ?? this.themeMode,
      highContrast: highContrast ?? this.highContrast,
      liquidGlass: liquidGlass ?? this.liquidGlass,
    );
  }

  Map<String, Object?> toJson() => {
        'seedId': seedId,
        'themeMode': themeMode.name,
        'highContrast': highContrast,
        'liquidGlass': liquidGlass,
      };

  static ThemePrefs fromJson(Map<String, Object?> json) {
    final modeName = json['themeMode'] as String? ?? 'system';
    final mode = ThemeMode.values.firstWhere(
      (m) => m.name == modeName,
      orElse: () => ThemeMode.system,
    );
    final seedId = json['seedId'] as String? ?? 'blue';
    // 未知 id 回退到最近预设，保证旧数据可迁移。
    final resolved = SeedPalette.presets.any((p) => p.id == seedId)
        ? seedId
        : SeedPalette.presets.first.id;
    return ThemePrefs(
      seedId: resolved,
      themeMode: mode,
      highContrast: json['highContrast'] as bool? ?? false,
      liquidGlass: json['liquidGlass'] as bool? ?? false,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ThemePrefs &&
        other.seedId == seedId &&
        other.themeMode == themeMode &&
        other.highContrast == highContrast &&
        other.liquidGlass == liquidGlass;
  }

  @override
  int get hashCode => Object.hash(seedId, themeMode, highContrast, liquidGlass);
}
