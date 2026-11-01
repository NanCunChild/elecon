import 'dart:convert';
import 'dart:io';
import 'package:elecon/ui/home/card_layout.dart';
import 'package:elecon/ui/home/card_layout_store.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

HomeCardEntry entry(String id) =>
    HomeCardEntry(id: id, label: id, builder: (_) => const SizedBox());

void main() {
  test('v1 migrates density and order into v3 presentation settings', () {
    final migrated = HomeCardLayout.fromJson({
      'version': 1,
      'order': ['notice', 'schedule', 'card'],
      'sizes': {'notice': 'compact', 'schedule': 'regular', 'card': 'expanded'},
    });
    expect(migrated.sizes, {
      'notice': HomeCardSize.regular,
      'schedule': HomeCardSize.expanded,
      'card': HomeCardSize.expanded,
    });
    expect(migrated.order, ['notice', 'schedule', 'card']);
    expect(migrated.toJson()['version'], 3);
    expect(migrated.hidden, isEmpty);
    expect(migrated.presets, isEmpty);
    expect(HomeCardLayout.fromJson(migrated.toJson()).sizes, migrated.sizes);
  });
  test(
    'v2 sizes and order survive with all cards visible and standard style',
    () {
      final migrated = HomeCardLayout.fromJson({
        'version': 2,
        'order': ['schedule', 'notice'],
        'sizes': {'schedule': 'compact', 'notice': 'regular'},
      });
      expect(migrated.order, ['schedule', 'notice']);
      expect(migrated.sizes, {
        'schedule': HomeCardSize.compact,
        'notice': HomeCardSize.regular,
      });
      expect(migrated.hidden, isEmpty);
      expect(migrated.presets, isEmpty);
    },
  );
  test(
    'hidden and missing cards retain order, size and independent preset',
    () {
      final cards = [entry('notice'), entry('schedule'), entry('new')];
      final layout =
          HomeCardLayout(
                order: ['library', 'notice', 'schedule'],
                hidden: {'notice', 'library'},
                presets: {'notice': 'future-style'},
              )
              .resize('notice', HomeCardSize.compact)
              .move('schedule', 'notice', cards);
      final restored = HomeCardLayout.fromJson(layout.toJson());
      expect(restored.visible(cards).map((c) => c.id), ['schedule', 'new']);
      expect(restored.order, ['library', 'schedule', 'notice', 'new']);
      expect(restored.hidden, {'notice', 'library'});
      expect(restored.presets['notice'], 'future-style');
      expect(
        entry('notice').supportedPreset(restored.presets['notice']),
        'standard',
      );
      final shown = restored.show('notice', true);
      expect(shown.visible(cards).map((c) => c.id), [
        'schedule',
        'notice',
        'new',
      ]);
      expect(shown.sizes['notice'], HomeCardSize.compact);
      expect(shown.presets['notice'], 'future-style');
      expect(shown.hidden, {'library'});
      expect(
        shown.selectPreset('notice', HomeCardPreset.standard).presets,
        isEmpty,
      );
    },
  );
  test(
    'v3 validates visibility and preset fields without losing valid layout',
    () {
      final parsed = HomeCardLayout.fromJson({
        'version': 3,
        'order': ['notice'],
        'sizes': {'notice': 'compact'},
        'hidden': ['notice', 'notice', 7, ''],
        'presets': {'notice': 'preview', '': 'bad', 'schedule': 1},
      });
      expect(parsed.hidden, {'notice'});
      expect(parsed.presets, {'notice': 'preview'});
      final oversized = HomeCardLayout.fromJson({
        ...parsed.toJson(),
        'hidden': List.filled(129, 'notice'),
        'presets': <String, Object>{
          for (var i = 0; i < 129; i++) '$i': 'preview',
        },
      });
      expect(oversized.hidden, isEmpty);
      expect(oversized.presets, isEmpty);
      expect(oversized.sizes['notice'], HomeCardSize.compact);
    },
  );
  test('missing capabilities retain their order and sizes', () {
    final layout = HomeCardLayout(
      order: ['library', 'notice', 'schedule'],
      sizes: {'library': HomeCardSize.compact},
    );
    final moved = layout.move('schedule', 'notice', [
      entry('notice'),
      entry('schedule'),
    ]);
    expect(moved.order, ['library', 'schedule', 'notice']);
    final restored = HomeCardLayout.fromJson(moved.toJson());
    expect(restored.sizes['library'], HomeCardSize.compact);
    expect(
      restored
          .arrange([entry('notice'), entry('schedule'), entry('library')])
          .map((e) => e.id),
      ['library', 'schedule', 'notice'],
    );
  });
  test('unknown versions and invalid fields fail safely', () {
    expect(HomeCardLayout.fromJson({'version': 4}).order, isEmpty);
    final parsed = HomeCardLayout.fromJson({
      'version': 1,
      'order': ['notice', 'notice', 4, ''],
      'sizes': {'notice': 'bad', 'schedule': 'compact'},
    });
    expect(parsed.order, ['notice']);
    expect(parsed.sizes, {
      'notice': HomeCardSize.expanded,
      'schedule': HomeCardSize.regular,
    });
    final card = HomeCardEntry(
      id: 'control',
      label: 'control',
      builder: (_) => const SizedBox(),
      sizes: const [HomeCardSize.regular],
      defaultSize: HomeCardSize.compact,
    );
    expect(card.supportedSize(HomeCardSize.expanded), HomeCardSize.regular);
  });
  test('school scopes persist independently and last save wins', () async {
    final dir = await Directory.systemTemp.createTemp('elecon-layout-test-');
    addTearDown(() => dir.delete(recursive: true));
    final store = CardLayoutStore(supportDirProvider: () => dir);
    await Future.wait([
      store.save('school/a', HomeCardLayout(order: ['notice', 'schedule'])),
      store.save('school/b', HomeCardLayout(order: ['notice'])),
      store.save(
        'school/a',
        HomeCardLayout(
          order: ['schedule', 'notice'],
          sizes: {'notice': HomeCardSize.compact},
          hidden: {'notice'},
          presets: {'notice': 'preview'},
        ),
      ),
    ]);
    final reopened = CardLayoutStore(supportDirProvider: () => dir);
    expect(
      (await reopened.load('school/a')).sizes['notice'],
      HomeCardSize.compact,
    );
    expect((await reopened.load('school/b')).sizes, isEmpty);
    expect((await reopened.load('school/a')).hidden, {'notice'});
    expect((await reopened.load('school/a')).presets, {'notice': 'preview'});
    expect((await reopened.load('school/b')).hidden, isEmpty);
    expect((await reopened.load('school/b')).presets, isEmpty);
    expect((await reopened.load('school/c')).order, isEmpty);
    final files = await Directory('${dir.path}/home-layout').list().toList();
    expect(files.length, 2);
    for (final file in files) {
      final json = jsonDecode(await File(file.path).readAsString()) as Map;
      expect(json.keys.toSet(), {
        'version',
        'order',
        'sizes',
        'hidden',
        'presets',
      });
    }
  });
  test('bad disk data falls back and does not poison future saves', () async {
    final dir = await Directory.systemTemp.createTemp('elecon-layout-corrupt-');
    addTearDown(() => dir.delete(recursive: true));
    final store = CardLayoutStore(supportDirProvider: () => dir);
    await store.save('school', HomeCardLayout(order: ['notice']));
    final file =
        (await Directory('${dir.path}/home-layout').list().toList()).single
            as File;
    await file.writeAsString('{bad');
    expect((await store.load('school')).order, isEmpty);
    await store.save('school', HomeCardLayout(order: ['schedule']));
    expect((await store.load('school')).order, ['schedule']);
  });
}
