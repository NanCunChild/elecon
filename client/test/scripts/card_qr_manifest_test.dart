import 'package:elecon/core/scripts/manifest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final manifest = <String, dynamic>{
    'sdkVersion': 6,
    'id': 'synthetic-card',
    'version': '1.0.0',
    'schoolId': 'synthetic',
    'name': 'Synthetic',
    'network': {
      'origins': ['https://school.example'],
    },
    'browser': false,
    'capabilities': [
      {'id': 'card.qr', 'schema': 'elecon.card.qr', 'schemaVersion': '1.0'},
    ],
    'cards': [
      {'type': 'card', 'defaultVariant': 'regular'},
    ],
  };
  test(
    'QR-only school can suggest a campus card without fake financial data',
    () {
      expect(ScriptManifest.fromJson(manifest).cards.single.type, 'card');
    },
  );
  test('QR cannot declare background loading or persistent home cache', () {
    for (final preload in [false, true]) {
      expect(
        () => ScriptManifest.fromJson({
          ...manifest,
          'home': [
            {'capability': 'card.qr', 'ttlSeconds': 30, 'preload': preload},
          ],
        }),
        throwsFormatException,
      );
    }
  });
}
