/// ADR-043 §2: finite, host-owned card presentation and local layout preferences.
library;

import 'package:flutter/widgets.dart';

enum HomeCardSize { compact, regular, expanded }

class HomeCardPresentation extends InheritedWidget {
  const HomeCardPresentation({
    super.key,
    required this.size,
    required super.child,
  });

  final HomeCardSize size;

  static HomeCardSize of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<HomeCardPresentation>()
          ?.size ??
      HomeCardSize.regular;

  @override
  bool updateShouldNotify(HomeCardPresentation oldWidget) =>
      size != oldWidget.size;
}

class HomeCardEntry {
  const HomeCardEntry({
    required this.id,
    required this.label,
    required this.builder,
    this.sizes = HomeCardSize.values,
    this.defaultSize = HomeCardSize.regular,
  }) : assert(id != ''),
       assert(sizes.length > 0);

  final String id;
  final String label;
  final WidgetBuilder builder;
  final List<HomeCardSize> sizes;
  final HomeCardSize defaultSize;

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
  }) : order = List.unmodifiable(order),
       sizes = Map.unmodifiable(sizes);

  final List<String> order;
  final Map<String, HomeCardSize> sizes;

  factory HomeCardLayout.fromJson(Object? value) {
    if (value is! Map || value['version'] != 1) return HomeCardLayout();
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
        if (entry.value == size.name) sizes[entry.key as String] = size;
      }
    }
    return HomeCardLayout(order: order, sizes: sizes);
  }

  static bool _validId(Object? id) =>
      id is String && id.isNotEmpty && id.length <= 256;

  Map<String, Object> toJson() => {
    'version': 1,
    'order': order,
    'sizes': sizes.map((id, size) => MapEntry(id, size.name)),
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

  HomeCardLayout resize(String id, HomeCardSize size) =>
      HomeCardLayout(order: order, sizes: {...sizes, id: size});

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
    return HomeCardLayout(order: fullOrder, sizes: sizes);
  }
}
