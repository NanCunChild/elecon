import 'package:elecon/core/messages/avatar.dart';
import 'package:elecon/ui/community/conversation_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const avatar =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

void main() {
  test('inline images reject URLs, non-raster and oversized content', () {
    expect(conversationAvatarBytes(avatar), isNotNull);
    for (final value in [
      'https://photo.chaoxing.com/a.png',
      'data:image/svg+xml;base64,PHN2Zz4=',
      'data:image/png;base64,YWJj',
      '$avatar!',
      'data:image/png;base64,${'A' * 22000}',
    ]) {
      expect(conversationAvatarBytes(value), isNull);
    }
  });
  for (final count in [0, 1, 2, 3, 4]) {
    testWidgets(
      'native mosaic renders $count images without shared image cache',
      (tester) async {
        final previousCacheSize = imageCache.currentSize;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ConversationAvatar(
                kind: 'group',
                images: List.filled(count, avatar),
              ),
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
        expect(find.byType(RawImage), findsNWidgets(count));
        if (count == 0) {
          expect(find.byIcon(Icons.group_outlined), findsOneWidget);
        }
        expect(imageCache.currentSize, previousCacheSize);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  testWidgets('bad image and disposal during decoding keep a safe fallback', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ConversationAvatar(
          kind: 'group',
          images: ['data:image/png;base64,iVBORw0KGgo='],
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(find.byIcon(Icons.group_outlined), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
