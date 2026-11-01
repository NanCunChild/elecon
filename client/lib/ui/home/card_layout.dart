/// ADR-043 §2: finite, host-owned card presentation and local layout preferences.
library;

import 'package:flutter/material.dart';

enum HomeCardSize { compact, regular, expanded }

/// Host-owned visual presets, independent of size and query/provider selection.
/// The business component reads [HomeCardPresentation.presetOf] and renders
/// the selected style from its existing data and state.
class HomeCardPreset {
  const HomeCardPreset({required this.id, required this.label})
    : assert(id != '' && id != standard);

  static const standard = 'standard';
  final String id;
  final String label;
}

class HomeCardPresentation extends InheritedWidget {
  const HomeCardPresentation({
    super.key,
    required this.size,
    this.preset = HomeCardPreset.standard,
    this.onOpen,
    this.icon = Icons.dashboard_outlined,
    required super.child,
  });

  final HomeCardSize size;
  final String preset;
  final VoidCallback? onOpen;
  final IconData icon;

  static HomeCardPresentation? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HomeCardPresentation>();

  static String presetOf(BuildContext context) =>
      maybeOf(context)?.preset ?? HomeCardPreset.standard;

  static bool isPreview(BuildContext context) =>
      maybeOf(context)?.onOpen != null && of(context) != HomeCardSize.expanded;

  static HomeCardSize of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<HomeCardPresentation>()
          ?.size ??
      HomeCardSize.expanded;

  @override
  bool updateShouldNotify(HomeCardPresentation oldWidget) =>
      size != oldWidget.size ||
      preset != oldWidget.preset ||
      onOpen != oldWidget.onOpen ||
      icon != oldWidget.icon;
}

class HomeCardEntry {
  const HomeCardEntry({
    required this.id,
    required this.label,
    required this.builder,
    this.icon = Icons.dashboard_outlined,
    this.sizes = HomeCardSize.values,
    this.defaultSize = HomeCardSize.regular,
    this.presets = const [],
  }) : assert(id != ''),
       assert(sizes.length > 0);

  final String id;
  final String label;
  final WidgetBuilder builder;
  final IconData icon;
  final List<HomeCardSize> sizes;
  final HomeCardSize defaultSize;

  /// Additional styles actually implemented by this card's native component.
  /// Standard is always available and need not be registered here.
  final List<HomeCardPreset> presets;

  String supportedPreset(String? preferred) =>
      presets.any((preset) => preset.id == preferred)
      ? preferred!
      : HomeCardPreset.standard;

  HomeCardSize supportedSize(HomeCardSize? preferred) {
    if (preferred != null && sizes.contains(preferred)) return preferred;
    if (sizes.contains(defaultSize)) return defaultSize;
    return sizes.first;
  }
}

/// Only order and presentation are stored; never business data or provider IDs.
class HomeCardLayout {
  HomeCardLayout({
    List<String> order = const [],
    Map<String, HomeCardSize> sizes = const {},
    Set<String> hidden = const {},
    Map<String, String> presets = const {},
  }) : order = List.unmodifiable(order),
       sizes = Map.unmodifiable(sizes),
       hidden = Set.unmodifiable(hidden),
       presets = Map.unmodifiable(presets);

  final List<String> order;
  final Map<String, HomeCardSize> sizes;
  final Set<String> hidden;
  final Map<String, String> presets;

  factory HomeCardLayout.fromJson(Object? value) {
    if (value is! Map || ![1, 2, 3].contains(value['version'])) {
      return HomeCardLayout();
    }
    final rawOrder = value['order'];
    final rawSizes = value['sizes'];
    if (rawOrder is! List ||
        rawSizes is! Map ||
        rawOrder.length > 128 ||
        rawSizes.length > 128) {
      return HomeCardLayout();
    }
    final order = <String>[];
    for (final id in rawOrder) {
      if (_validId(id) && !order.contains(id)) order.add(id as String);
    }
    final sizes = <String, HomeCardSize>{};
    for (final entry in rawSizes.entries) {
      if (!_validId(entry.key)) continue;
      for (final size in HomeCardSize.values) {
        if (entry.value == size.name) {
          sizes[entry.key as String] = value['version'] == 1
              ? (size == HomeCardSize.compact
                    ? HomeCardSize.regular
                    : HomeCardSize.expanded)
              : size;
        }
      }
    }
    if (value['version'] == 1) {
      for (final id in order) {
        sizes.putIfAbsent(id, () => HomeCardSize.expanded);
      }
    }
    final hidden = <String>{};
    final presets = <String, String>{};
    if (value['version'] == 3) {
      final rawHidden = value['hidden'];
      final rawPresets = value['presets'];
      if (rawHidden is List && rawHidden.length <= 128) {
        hidden.addAll(rawHidden.where(_validId).cast<String>());
      }
      if (rawPresets is Map && rawPresets.length <= 128) {
        for (final entry in rawPresets.entries) {
          if (_validId(entry.key) && _validId(entry.value)) {
            presets[entry.key as String] = entry.value as String;
          }
        }
      }
    }
    return HomeCardLayout(
      order: order,
      sizes: sizes,
      hidden: hidden,
      presets: presets,
    );
  }

  static bool _validId(Object? id) =>
      id is String && id.isNotEmpty && id.length <= 256;

  Map<String, Object> toJson() => {
    'version': 3,
    'order': order,
    'sizes': sizes.map((id, size) => MapEntry(id, size.name)),
    'hidden': hidden.toList(),
    'presets': presets,
  };

  List<HomeCardEntry> arrange(List<HomeCardEntry> cards) {
    final remaining = {for (final card in cards) card.id: card};
    final result = <HomeCardEntry>[];
    for (final id in order) {
      final card = remaining.remove(id);
      if (card != null) result.add(card);
    }
    result.addAll(remaining.values);
    return result;
  }

  List<HomeCardEntry> visible(List<HomeCardEntry> cards) =>
      arrange(cards).where((card) => !hidden.contains(card.id)).toList();

  HomeCardLayout resize(String id, HomeCardSize size) => HomeCardLayout(
    order: order,
    sizes: {...sizes, id: size},
    hidden: hidden,
    presets: presets,
  );

  HomeCardLayout show(String id, bool visible) => HomeCardLayout(
    order: order,
    sizes: sizes,
    hidden: visible ? (Set.of(hidden)..remove(id)) : {...hidden, id},
    presets: presets,
  );

  HomeCardLayout selectPreset(String id, String preset) => HomeCardLayout(
    order: order,
    sizes: sizes,
    hidden: hidden,
    presets: preset == HomeCardPreset.standard
        ? (Map.of(presets)..remove(id))
        : {...presets, id: preset},
  );

  /// Retain missing cards and their preferences when capabilities are transient.
  HomeCardLayout move(String from, String to, List<HomeCardEntry> cards) {
    final fullOrder = [
      ...order,
      for (final card in cards)
        if (!order.contains(card.id)) card.id,
    ];
    final fromIndex = fullOrder.indexOf(from);
    final toIndex = fullOrder.indexOf(to);
    if (fromIndex < 0 || toIndex < 0 || fromIndex == toIndex) return this;
    fullOrder.removeAt(fromIndex);
    fullOrder.insert(toIndex, from);
    return HomeCardLayout(
      order: fullOrder,
      sizes: sizes,
      hidden: hidden,
      presets: presets,
    );
  }
}
