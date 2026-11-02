import 'dart:io';

import 'package:elecon/core/transport/app_tunnel.dart';
import 'package:elecon/core/transport/hermes/native_binding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final path =
      Platform.environment['ELECON_HERMES_TEST_LIBRARY'] ??
      '${Directory.current.parent.path}/native/hermes_app_tunnel/target/debug/libelecon_hermes.so';
  final available = Platform.isLinux && File(path).existsSync();
  group(
    'actual Hermes C ABI in worker isolates',
    () {
      final binding = HermesNativeBinding(libraryPath: path);
      test(
        'loads bundled symbols; rejects invalid gateway before network',
        () async {
          expect(binding.isAvailable, isTrue);
          expect(
            (await binding.request({'op': 'version'}).result)['version'],
            1,
          );
          await expectLater(
            binding.request({
              'op': 'start',
              'gatewayUrl': 'http://not-a-real-gateway.invalid',
              'session': {},
            }).result,
            throwsA(
              isA<AppTunnelException>().having(
                (e) => e.code,
                'code',
                'hermes_invalid_configuration',
              ),
            ),
          );
        },
      );
      test(
        'parallel native errors stay bounded and contain no request values',
        () async {
          await Future.wait([
            for (var i = 0; i < 12; i++)
              expectLater(
                binding.request({
                  'op': 'unknown',
                  'secret': 'SYNTHETIC_PRIVATE_$i',
                }).result,
                throwsA(
                  isA<AppTunnelException>()
                      .having((e) => e.code, 'code', 'hermes_invalid_request')
                      .having(
                        (e) => e.toString(),
                        'safe error',
                        isNot(contains('SYNTHETIC_PRIVATE')),
                      ),
                ),
              ),
          ]);
        },
      );
      test('closed native handle cannot resolve a host', () async {
        await expectLater(
          binding.request({
            'op': 'resolve',
            'handle': 9223372036854775807,
            'host': 'not-a-real-school.invalid',
          }).result,
          throwsA(
            isA<AppTunnelException>().having(
              (e) => e.code,
              'code',
              'hermes_closed',
            ),
          ),
        );
      });
    },
    skip: available
        ? false
        : 'Build native/hermes_app_tunnel first; no native library is bundled in the Flutter test runner.',
  );
}
