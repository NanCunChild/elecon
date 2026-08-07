/// ADR-026 Dart delivery firewall / credential Commit 原语测试。
/// 🔒 红线 #1：与实现一并须人工 + 安全清单实质复核，不得据此自行关闭 P0-10。
library;

import 'package:elecon/core/broker/delivery_firewall.dart';
import 'package:elecon/core/broker/inject_policy.dart';
import 'package:elecon/core/broker/masker_commit.dart';
import 'package:elecon/core/broker/response_masker.dart';
import 'package:elecon/core/credential/types.dart';
import 'package:flutter_test/flutter_test.dart';

const _view = BrokerManifestView(
  allow: ['https://school.example/*'],
  credentials: {
    'session': CredentialDecl(
      scope: ['https://school.example/*'],
      type: 'header',
      headerName: 'x-session',
    ),
  },
);

const _rule = MaskerRule(
  id: 'r-session',
  capture: MaskerCaptureDecl(
    source: 'json',
    destinationKind: 'credential',
    path: r'$.token',
    destinationRef: 'session',
  ),
  project: 'replace',
);

void main() {
  test(
    'Capture/Project/Commit closes over explicitly supplied dependencies',
    () {
      final writes = <CredentialEntry>[];
      final result = deliverThroughFirewall(
        raw: const MaskerRawResponse(
          status: 200,
          headers: {'content-type': 'application/json', 'set-cookie': 's=1'},
          body: '{"token":"SECRET_FIXTURE","items":[1]}',
        ),
        transportDecodeOk: true,
        rules: const [_rule],
        view: _view,
        sink: writes.add,
        context: MaskerCommitContext(schoolId: 'demo', now: () => 1234),
      );

      expect(result.response.body, contains(maskerSentinel));
      expect(result.response.body, isNot(contains('SECRET_FIXTURE')));
      expect(result.response.headers, isNot(contains('set-cookie')));
      expect(result.committedCount, 1);
      expect(writes.single.ref, 'session');
      expect(writes.single.value, 'SECRET_FIXTURE');
      expect(
        writes.single.scope,
        isNot(same(_view.credentials['session']!.scope)),
      );
    },
  );

  test(
    'cancellation immediately before irreversible Commit writes no sink',
    () {
      final writes = <CredentialEntry>[];
      var checks = 0;

      expect(
        () => deliverThroughFirewall(
          raw: const MaskerRawResponse(
            status: 200,
            headers: {'content-type': 'application/json'},
            body: '{"token":"LATE_SECRET"}',
          ),
          transportDecodeOk: true,
          rules: const [_rule],
          view: _view,
          sink: writes.add,
          context: MaskerCommitContext(schoolId: 'demo', now: () => 1234),
          isCancelled: () => ++checks == 2,
        ),
        throwsA(
          isA<DeliveryFirewallException>().having(
            (error) => error.code,
            'code',
            'delivery_cancelled',
          ),
        ),
      );
      expect(writes, isEmpty);
    },
  );

  test('selector miss delivers without replacing an existing credential', () {
    const existing = CredentialEntry(
      ref: 'session',
      schoolId: 'demo',
      type: 'header',
      scope: ['https://school.example/*'],
      value: 'OLD_FIXTURE_SECRET',
      acquiredAt: 1000,
      expiresAt: 9000,
      status: CredentialStatus.active,
    );
    final writes = <CredentialEntry>[];
    final result = deliverThroughFirewall(
      raw: const MaskerRawResponse(
        status: 200,
        headers: {'content-type': 'application/json'},
        body: '{"business":"ok"}',
      ),
      transportDecodeOk: true,
      rules: const [
        MaskerRule(
          id: 'r-missing',
          capture: MaskerCaptureDecl(
            source: 'json',
            destinationKind: 'credential',
            path: r'$.missing',
            destinationRef: 'session',
          ),
          project: 'replace',
        ),
      ],
      view: _view,
      sink: writes.add,
      context: MaskerCommitContext(schoolId: 'demo', now: () => 2000),
    );

    expect(result.response.body, '{"business":"ok"}');
    expect(result.committedCount, 0);
    expect(writes, isEmpty);
    expect(existing.value, 'OLD_FIXTURE_SECRET');
    expect(existing.status, CredentialStatus.active);
    expect(existing.acquiredAt, 1000);
    expect(existing.expiresAt, 9000);
  });

  test(
    'Commit planner rejects multiple or undeclared credential targets before writes',
    () {
      final captures = [
        const CapturedCredential(ruleId: 'a', ref: 'session', value: 'A'),
        const CapturedCredential(ruleId: 'b', ref: 'session', value: 'B'),
      ];
      expect(
        () => planMaskerCommit(
          captures,
          _view,
          MaskerCommitContext(schoolId: 'demo', now: () => 1),
        ),
        throwsA(
          isA<MaskerCommitException>().having(
            (error) => error.code,
            'code',
            'commit_multiple_credentials',
          ),
        ),
      );
      expect(
        () => planMaskerCommit(
          const [CapturedCredential(ruleId: 'x', ref: 'missing', value: 'X')],
          _view,
          MaskerCommitContext(schoolId: 'demo', now: () => 1),
        ),
        throwsA(
          isA<MaskerCommitException>().having(
            (error) => error.code,
            'code',
            'commit_ref_undeclared',
          ),
        ),
      );
    },
  );
}
