import 'dart:convert';

import 'package:elecon/core/credential/blob_store.dart';
import 'package:elecon/core/credential/secure_store.dart';
import 'package:elecon/core/credential/software_secure_store.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/transport/app_tunnel.dart';
import 'package:elecon/core/transport/hermes/hermes.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> syntheticSession() => {
  'version': 1,
  'gateway_host': 'gateway.example.invalid',
  'gateway_port': 443,
  'cookies': [
    {'name': 'sid', 'value': 'SYNTHETIC_PRIVATE_SID'},
  ],
  'sid': 'SYNTHETIC_PRIVATE_SID',
  'device_id': 'SYNTHETIC_LOGICAL_DEVICE',
  'connection_id': 'SYNTHETIC_LOGICAL_CONNECTION',
  'sign_key_hex': '00' * 32,
};
HermesConfiguration configuration() => HermesConfiguration(
  gatewayUrl: 'https://gateway.example.invalid/',
  nodeCertificateSha256: 'ab' * 32,
  session: syntheticSession(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'gateway binding, certificate fingerprint and version are validated',
    () {
      expect(
        configuration().info.gatewayUrl,
        'https://gateway.example.invalid',
      );
      for (final address in [
        'http://gateway.example.invalid',
        'https://user:password@gateway.example.invalid',
        'https://gateway.example.invalid/?ticket=SECRET',
        'https://gateway.example.invalid/portal',
      ]) {
        expect(
          () => HermesConfiguration(
            gatewayUrl: address,
            session: syntheticSession(),
          ),
          throwsA(isA<AppTunnelException>()),
        );
      }
      expect(
        () => HermesConfiguration(
          gatewayUrl: 'https://other.example.invalid',
          session: syntheticSession(),
        ),
        throwsA(isA<AppTunnelException>()),
      );
      expect(
        () => HermesConfiguration(
          gatewayUrl: 'https://gateway.example.invalid',
          session: {...syntheticSession(), 'version': 2},
        ),
        throwsA(isA<AppTunnelException>()),
      );
      expect(
        () => HermesConfiguration.validatePin('not-a-certificate'),
        throwsA(isA<AppTunnelException>()),
      );
      expect(HermesConfiguration.validatePin(''), isNull);
      expect(
        configuration().toString(),
        isNot(contains('SYNTHETIC_PRIVATE_SID')),
      );
    },
  );

  test(
    'protected session survives restart without plaintext or school/script access',
    () async {
      final blobs = InMemoryBlobStore();
      final backend = await SoftwareSecureStore.open(blobs);
      final credentials = CredentialStore(store: backend);
      final store = HermesConfigStore(credentials);
      store.save('synthetic-school', configuration());
      final revision = store.revision('synthetic-school');
      expect(store.load('other-school'), isNull);
      expect(
        ScriptCredentials(
          store: credentials,
          schoolId: 'synthetic-school',
          scriptId: 'synthetic-script',
          sdkVersion: 9,
        ).list(),
        isEmpty,
      );
      await backend.flush();
      final encrypted = utf8.decode(
        (await blobs.read('store.enc'))!,
        allowMalformed: true,
      );
      expect(encrypted, isNot(contains('SYNTHETIC_PRIVATE_SID')));
      expect(encrypted, isNot(contains('gateway.example.invalid')));
      final restored = HermesConfigStore(
        CredentialStore(store: await SoftwareSecureStore.open(blobs)),
      );
      expect(
        restored.load('synthetic-school')!.info.gatewayUrl,
        'https://gateway.example.invalid',
      );
      expect(
        restored.load('synthetic-school')!.info.nodeCertificateSha256,
        'ab' * 32,
      );
      store.clear('synthetic-school');
      expect(store.load('synthetic-school'), isNull);
      expect(identical(revision, store.revision('synthetic-school')), isFalse);
      expect(
        HermesConfigStore(
          CredentialStore(store: InMemorySecureStore(releaseMode: false)),
        ).load('synthetic-school'),
        isNull,
      );
    },
  );

  test(
    'missing native library fails with a bounded code and no control secrets',
    () async {
      final binding = HermesNativeBinding(
        libraryPath: '/nonexistent/synthetic-hermes-library.so',
      );
      expect(binding.isAvailable, isFalse);
      await expectLater(
        binding.request({'op': 'start', 'session': syntheticSession()}).result,
        throwsA(
          isA<AppTunnelException>().having(
            (e) => e.code,
            'code',
            'app_tunnel_unavailable',
          ),
        ),
      );
    },
  );

  test(
    'login navigation reports origins only and rejects undeclared destinations',
    () async {
      var active = true;
      var saves = 0;
      final bridge = HermesLoginBridge(
        gatewayUrl: 'https://gateway.example.invalid',
        allowedOrigins: {'https://identity.example.invalid'},
        isActive: () => active,
        save: (_) async {
          saves++;
        },
      );
      expect(
        bridge.navigationAllowed(
          'https://identity.example.invalid/cas?ticket=SYNTHETIC_TICKET',
        ),
        isTrue,
      );
      expect(bridge.state.value.origin, 'https://identity.example.invalid');
      expect(bridge.state.value.origin, isNot(contains('SYNTHETIC_TICKET')));
      expect(
        bridge.navigationAllowed('https://unknown.example.invalid'),
        isFalse,
      );
      expect(bridge.state.value.phase, HermesLoginPhase.blocked);
      expect(
        bridge.navigationAllowed('http://gateway.example.invalid'),
        isFalse,
      );
      active = false;
      expect(
        bridge.navigationAllowed('https://gateway.example.invalid'),
        isFalse,
      );
      bridge.dispose();
      await bridge.stop();
      expect(saves, 0);
    },
  );
}
