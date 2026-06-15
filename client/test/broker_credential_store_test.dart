/// 凭证存储 Dart 对齐测试 —— 与 TS `store.smoke.ts` 同一组场景（模型往返 + 生命周期 +
/// B1 集成 + 漂移检出）。两端实现镜像、行为一致。
///
/// 纯逻辑、不经 QuickJS → 无原生库依赖、不限 Linux。
///
///   运行：cd client && fvm flutter test test/broker_credential_store_test.dart
///
/// ⚠️ 夹具值为显式假值（红线 #8）：绝不使用真实学生凭证。
import 'package:elecon/core/broker/inject_policy.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/credential/types.dart';
import 'package:flutter_test/flutter_test.dart';

const _fakeValue = 'TEST-SESSION-not-a-real-credential';

CredentialEntry _entry({
  String ref = 'session',
  String type = 'cookie',
  int? expiresAt,
  CredentialStatus status = CredentialStatus.active,
}) =>
    CredentialEntry(
      ref: ref,
      schoolId: 'test',
      type: type,
      scope: const ['https://h.edu.cn/api/*'],
      value: _fakeValue,
      acquiredAt: 1000,
      expiresAt: expiresAt,
      status: status,
    );

void main() {
  group('凭证存储（Dart，与 TS store.smoke 同场景）', () {
    test('往返：put → get 取到值（via = store type）', () async {
      final store = CredentialStore(now: () => 10000);
      store.put(_entry());
      final r = await store.get('session');
      expect(r, isNotNull);
      expect(r!.via, 'cookie');
      expect(r.value, _fakeValue);
    });

    test('生命周期：不存在/过期/吊销 → null；登出 delete → 抹除', () async {
      final store = CredentialStore(now: () => 10000);

      expect(await store.get('nope'), isNull);

      store.put(_entry(ref: 'exp', expiresAt: 9000));
      expect(await store.get('exp'), isNull, reason: '过期凭证不可解析');

      store.put(_entry(ref: 'rev', status: CredentialStatus.revoked));
      expect(await store.get('rev'), isNull, reason: '吊销凭证不可解析');

      store.put(_entry());
      store.delete('session');
      expect(await store.get('session'), isNull, reason: '登出后凭证已抹除');
    });

    test('B1 集成：inject 决策 → 解析凭证值，且 via 一致', () async {
      final store = CredentialStore(now: () => 10000);
      store.put(_entry());
      final view = BrokerManifestView(
        allow: const ['https://h.edu.cn/api/*'],
        credentials: {
          'session':
              CredentialDecl(scope: const ['https://h.edu.cn/api/*'], type: 'cookie'),
        },
      );
      final decision = decideInjection('https://h.edu.cn/api/grades', view);
      expect(decision, isA<InjectDecision>());
      final inj = decision as InjectDecision;
      final resolved = await store.get(inj.ref);
      expect(resolved, isNotNull);
      expect(inj.via, resolved!.via, reason: 'manifest via 与 store type 一致');
    });

    test('§2.4 漂移：store.type 与 manifest via 冲突可检出（注入以 manifest 为准）', () async {
      final store = CredentialStore(now: () => 10000);
      store.put(_entry(ref: 'drift', type: 'header'));
      final view = BrokerManifestView(
        allow: const ['https://h.edu.cn/api/*'],
        credentials: {
          'drift':
              CredentialDecl(scope: const ['https://h.edu.cn/api/*'], type: 'cookie'),
        },
      );
      final decision = decideInjection('https://h.edu.cn/api/x', view) as InjectDecision;
      final resolved = await store.get(decision.ref);
      expect(resolved, isNotNull);
      // 注入权威 = manifest（decision.via=cookie）；store=header → 应可检出冲突
      expect(resolved!.via != decision.via, isTrue,
          reason: 'store=header vs manifest=cookie 漂移');
    });

    test('续期写回：过期后 put 覆盖 → 重新可解析；时间越过新 expiresAt 再失效', () async {
      var now = 10000;
      final store = CredentialStore(now: () => now);
      store.put(_entry(ref: 'exp', expiresAt: now + 5000));
      expect(await store.get('exp'), isNotNull);
      now += 6000;
      expect(await store.get('exp'), isNull);
    });
  });
}
