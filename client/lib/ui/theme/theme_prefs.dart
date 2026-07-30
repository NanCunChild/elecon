/// 显示偏好：主题色 / 明暗 / 语言 / 无障碍高对比 / 实验性液态玻璃。
///
/// 高对比是无障碍开关，启用后覆盖全部主题的色面与对比策略，
/// 不是与浅色/深色并列的第三种主题模式。
///
/// 语言（[ThemePrefs.localeTag]）与主题同属「用户可调的显示偏好」，共用一份落盘，
/// 不为一个字符串再开一套 store / controller / scope。
library;

import 'package:flutter/material.dart';

/// 预设主题色（seed），UI 以色点展示。
///
/// [id] 是落盘键与 l10n 键的连接点：显示名不在此，由
/// `appearance_section.dart` 按 id 取 `l10n.appearanceSeed*`（文案单源在 arb）。
class SeedPalette {
  const SeedPalette({required this.id, required this.seed});

  final String id;
  final Color seed;

  static const List<SeedPalette> presets = [
    SeedPalette(id: 'blue', seed: Color(0xff3867d6)),
    SeedPalette(id: 'indigo', seed: Color(0xff3f51b5)),
    SeedPalette(id: 'teal', seed: Color(0xff0d9488)),
    SeedPalette(id: 'green', seed: Color(0xff2e7d32)),
    SeedPalette(id: 'amber', seed: Color(0xfff59e0b)),
    SeedPalette(id: 'orange', seed: Color(0xffea580c)),
    SeedPalette(id: 'rose', seed: Color(0xffe11d48)),
    SeedPalette(id: 'violet', seed: Color(0xff7c3aed)),
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

/// 可序列化的显示偏好。
class ThemePrefs {
  const ThemePrefs({
    this.seedId = 'blue',
    this.themeMode = ThemeMode.system,
    this.highContrast = false,
    this.liquidGlass = false,
    this.localeTag,
  });

  final String seedId;
  final ThemeMode themeMode;
  final bool highContrast;
  final bool liquidGlass;

  /// 语言标签（`zh` / `en`）；`null` = 跟随系统。
  ///
  /// 只存原样字符串，是否受支持由 `ui/i18n/locale_options.dart` 按
  /// `AppLocalizations.supportedLocales`（即 arb 文件集）判定——避免在此
  /// 复制一份语言清单。
  final String? localeTag;

  static const ThemePrefs defaults = ThemePrefs();

  /// copyWith 的「保持原值」哨兵：可空字段无法用 `null` 表达「不改」。
  static const Object _keep = Object();

  Color get seedColor => SeedPalette.byId(seedId).seed;

  /// 高对比启用时强制关闭液态玻璃视觉（玻璃半透明会降低对比度）。
  bool get effectiveLiquidGlass => liquidGlass && !highContrast;

  /// [localeTag] 传 `null` 表示「改为跟随系统」，不传表示「保持不变」。
  ThemePrefs copyWith({
    String? seedId,
    ThemeMode? themeMode,
    bool? highContrast,
    bool? liquidGlass,
    Object? localeTag = _keep,
  }) {
    return ThemePrefs(
      seedId: seedId ?? this.seedId,
      themeMode: themeMode ?? this.themeMode,
      highContrast: highContrast ?? this.highContrast,
      liquidGlass: liquidGlass ?? this.liquidGlass,
      localeTag: localeTag == _keep ? this.localeTag : localeTag as String?,
    );
  }

  Map<String, Object?> toJson() => {
        'seedId': seedId,
        'themeMode': themeMode.name,
        'highContrast': highContrast,
        'liquidGlass': liquidGlass,
        // 跟随系统时不写键，旧版本读到缺键同样得到「跟随系统」。
        if (localeTag != null) 'localeTag': localeTag,
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
    final localeTag = json['localeTag'] as String?;
    return ThemePrefs(
      seedId: resolved,
      themeMode: mode,
      highContrast: json['highContrast'] as bool? ?? false,
      liquidGlass: json['liquidGlass'] as bool? ?? false,
      // 空串等脏值一律按「跟随系统」处理（受支持与否在 locale_options 判定）。
      localeTag: (localeTag == null || localeTag.isEmpty) ? null : localeTag,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ThemePrefs &&
        other.seedId == seedId &&
        other.themeMode == themeMode &&
        other.highContrast == highContrast &&
        other.liquidGlass == liquidGlass &&
        other.localeTag == localeTag;
  }

  @override
  int get hashCode =>
      Object.hash(seedId, themeMode, highContrast, liquidGlass, localeTag);
}
