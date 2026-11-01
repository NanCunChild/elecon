/// Integer cell placement with vertical gravity and a pinned drag target.
library;

import 'dart:math' as math;
import 'card_layout.dart';

class HomeCardSpan {
  const HomeCardSpan(this.columns, this.rows);
  final int columns;
  final int rows;
}

class HomeCardGrid {
  HomeCardGrid({required this.width, required double labelHeight})
    : columns = width < 280 ? 2 : 4,
      cellWidth =
          (width - gap * ((width < 280 ? 2 : 4) - 1)) / (width < 280 ? 2 : 4) {
    cellHeight = math
        .max(cellWidth, 32 + 6 + 16 + labelHeight * 2)
        .ceilToDouble();
  }

  static const gap = 12.0;
  final double width;
  final int columns;
  final double cellWidth;
  late final double cellHeight;

  double widthOf(HomeCardSpan span) => span.columns * (cellWidth + gap) - gap;
  double heightOf(HomeCardSpan span) => span.rows * (cellHeight + gap) - gap;

  HomeCardSpan span(HomeCardSize size, {double contentHeight = 0}) =>
      switch (size) {
        HomeCardSize.compact => const HomeCardSpan(1, 1),
        HomeCardSize.regular => const HomeCardSpan(2, 2),
        HomeCardSize.expanded => HomeCardSpan(
          columns,
          math.max(2, ((contentHeight + gap) / (cellHeight + gap)).ceil()),
        ),
      };

  /// Reserve explicit positions before filling gaps. The dragged item owns its
  /// target first; only colliding items are displaced. Stable input order breaks
  /// ties, including malformed or now-incompatible stored layouts.
  Map<String, HomeCardPosition> place(
    Map<String, HomeCardSpan> spans,
    Map<String, HomeCardPosition> preferred, {
    String? priority,
  }) {
    final result = <String, HomeCardPosition>{};
    final occupied = <(int, int)>{};
    bool fits(HomeCardPosition p, HomeCardSpan s) {
      for (var row = p.row; row < p.row + s.rows; row++) {
        for (var col = p.column; col < p.column + s.columns; col++) {
          if (occupied.contains((col, row))) return false;
        }
      }
      return true;
    }

    void put(String id, HomeCardPosition p) {
      result[id] = p;
      final span = spans[id]!;
      for (var row = p.row; row < p.row + span.rows; row++) {
        for (var col = p.column; col < p.column + span.columns; col++) {
          occupied.add((col, row));
        }
      }
    }

    final ids = [
      if (priority != null && spans.containsKey(priority)) priority,
      ...spans.keys.where((id) => id != priority),
    ];
    for (final id in ids) {
      final p = preferred[id];
      if (p == null) continue;
      final adjusted = HomeCardPosition(
        p.column.clamp(0, columns - spans[id]!.columns),
        p.row.clamp(0, 1023),
      );
      if (fits(adjusted, spans[id]!)) put(id, adjusted);
    }
    for (final id in ids.where((id) => !result.containsKey(id))) {
      final span = spans[id]!;
      var row = 0;
      var placed = false;
      while (!placed) {
        for (var column = 0; column <= columns - span.columns; column++) {
          final p = HomeCardPosition(column, row);
          if (fits(p, span)) {
            put(id, p);
            placed = true;
            break;
          }
        }
        row++;
      }
    }
    // Settle from top to bottom without changing columns or crossing cards.
    // A live drag target stays pinned until drop; normal builds settle all cards.
    final settling = result.keys.toList()
      ..sort((a, b) {
        final row = result[a]!.row.compareTo(result[b]!.row);
        return row != 0 ? row : result[a]!.column.compareTo(result[b]!.column);
      });
    for (final id in settling) {
      if (id == priority) continue;
      final old = result[id]!;
      final span = spans[id]!;
      for (var row = old.row; row < old.row + span.rows; row++) {
        for (var col = old.column; col < old.column + span.columns; col++) {
          occupied.remove((col, row));
        }
      }
      var row = old.row;
      while (row > 0 && fits(HomeCardPosition(old.column, row - 1), span)) {
        row--;
      }
      put(id, HomeCardPosition(old.column, row));
    }
    return result;
  }
}
