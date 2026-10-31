import 'dart:convert';
import 'dart:io';
import 'package:elecon/ui/home/card_layout.dart';
import 'package:elecon/ui/home/card_layout_store.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

HomeCardEntry entry(String id) =>
    HomeCardEntry(id: id, label: id, builder: (_) => const SizedBox());

void main() {
  test('v1 migrates density and order; v2 round trips', () {
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
    expect(migrated.toJson()['version'], 2);
    expect(HomeCardLayout.fromJson(migrated.toJson()).sizes, migrated.sizes);
  });
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
    expect(HomeCardLayout.fromJson({'version': 3}).order, isEmpty);
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
        ),
      ),
    ]);
    final reopened = CardLayoutStore(supportDirProvider: () => dir);
    expect(
      (await reopened.load('school/a')).sizes['notice'],
      HomeCardSize.compact,
    );
    expect((await reopened.load('school/b')).sizes, isEmpty);
    expect((await reopened.load('school/c')).order, isEmpty);
    final files = await Directory('${dir.path}/home-layout').list().toList();
    expect(files.length, 2);
    for (final file in files) {
      final json = jsonDecode(await File(file.path).readAsString()) as Map;
      expect(json.keys.toSet(), {'version', 'order', 'sizes'});
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
