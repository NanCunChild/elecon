import 'package:elecon/ui/home/card_grid.dart';
import 'package:elecon/ui/home/card_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('four single cells and their gaps equal one two-by-two summary', () {
    for (final width in [288.0, 400.0, 900.0]) {
      for (final labelHeight in [16.0, 32.0]) {
        final grid = HomeCardGrid(width: width, labelHeight: labelHeight);
        final icon = grid.span(HomeCardSize.compact);
        final summary = grid.span(HomeCardSize.regular);
        expect(
          grid.widthOf(summary),
          grid.widthOf(icon) * 2 + HomeCardGrid.gap,
        );
        expect(
          grid.heightOf(summary),
          grid.heightOf(icon) * 2 + HomeCardGrid.gap,
        );
      }
    }
  });
  test('summary and four icons share two rows without row-flow gaps', () {
    final grid = HomeCardGrid(width: 400, labelHeight: 16);
    final placed = grid.place({
      'summary': grid.span(HomeCardSize.regular),
      for (var i = 0; i < 4; i++) 'icon$i': grid.span(HomeCardSize.compact),
    }, {});
    expect(placed, {
      'summary': const HomeCardPosition(0, 0),
      'icon0': const HomeCardPosition(2, 0),
      'icon1': const HomeCardPosition(3, 0),
      'icon2': const HomeCardPosition(2, 1),
      'icon3': const HomeCardPosition(3, 1),
    });
  });
  test('saved gaps settle upward while the live drag target stays pinned', () {
    final grid = HomeCardGrid(width: 400, labelHeight: 16);
    final spans = {
      'a': grid.span(HomeCardSize.compact),
      'b': grid.span(HomeCardSize.regular),
      'c': grid.span(HomeCardSize.compact),
    };
    final placed = grid.place(spans, {
      'a': const HomeCardPosition(3, 3),
      'b': const HomeCardPosition(1, 1),
      'c': const HomeCardPosition(0, 0),
    });
    expect(placed['a'], const HomeCardPosition(3, 0));
    expect(placed['b'], const HomeCardPosition(1, 0));
    final dragged = grid.place(spans, {
      ...placed,
      'a': const HomeCardPosition(2, 1),
    }, priority: 'a');
    expect(dragged['a'], const HomeCardPosition(2, 1));
    expect(grid.place(spans, dragged)['a']!.row, lessThanOrEqualTo(1));
    expect(dragged['b'], isNot(placed['b']));
    expect(dragged['c'], placed['c']);
  });
  test(
    'narrow screens adapt coordinates without changing saved preferences',
    () {
      final preferred = {'a': const HomeCardPosition(3, 2)};
      final narrow = HomeCardGrid(width: 240, labelHeight: 16);
      expect(
        narrow.place({'a': narrow.span(HomeCardSize.compact)}, preferred)['a'],
        const HomeCardPosition(1, 0),
      );
      final wide = HomeCardGrid(width: 400, labelHeight: 16);
      expect(
        wide.place({'a': wide.span(HomeCardSize.compact)}, preferred)['a'],
        const HomeCardPosition(3, 0),
      );
    },
  );
  test('hiding or shrinking a card releases the space below it', () {
    final grid = HomeCardGrid(width: 400, labelHeight: 16);
    const saved = {
      'top': HomeCardPosition(0, 0),
      'bottom': HomeCardPosition(0, 5),
    };
    expect(grid.place({
      'top': grid.span(HomeCardSize.regular),
      'bottom': grid.span(HomeCardSize.compact),
    }, saved)['bottom'], const HomeCardPosition(0, 2));
    expect(grid.place({
      'top': grid.span(HomeCardSize.compact),
      'bottom': grid.span(HomeCardSize.compact),
    }, saved)['bottom'], const HomeCardPosition(0, 1));
    expect(grid.place({
      'bottom': grid.span(HomeCardSize.compact),
    }, saved)['bottom'], const HomeCardPosition(0, 0));
  });
  test('mixed sizes, collisions and tall details never overlap', () {
    final grid = HomeCardGrid(width: 400, labelHeight: 16);
    final spans = {
      for (var i = 0; i < 40; i++)
        '$i': grid.span(HomeCardSize.values[i % 3], contentHeight: 530),
    };
    final placed = grid.place(spans, {
      for (var i = 0; i < 40; i++) '$i': HomeCardPosition(i % 4, i % 7),
    }, priority: '20');
    final occupied = <(int, int)>{};
    for (final entry in placed.entries) {
      final span = spans[entry.key]!;
      expect(entry.value.column + span.columns, lessThanOrEqualTo(4));
      for (var y = entry.value.row; y < entry.value.row + span.rows; y++) {
        for (
          var x = entry.value.column;
          x < entry.value.column + span.columns;
          x++
        ) {
          expect(occupied.add((x, y)), isTrue, reason: 'overlap at $x,$y');
        }
      }
    }
    final details = grid.span(HomeCardSize.expanded, contentHeight: 530);
    expect(grid.heightOf(details), greaterThanOrEqualTo(530));
    expect(
      grid.heightOf(details) - 530,
      lessThan(grid.cellHeight + HomeCardGrid.gap),
    );
  });
}
