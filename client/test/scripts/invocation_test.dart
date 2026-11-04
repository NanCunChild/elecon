import 'dart:async';
import 'dart:convert';

import 'package:elecon/core/scripts/invocation.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

ScriptPackage fixture() => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': 17,
      'id': 'synthetic.invocation',
      'schoolId': 'synthetic',
      'version': '1.0.0',
      'name': 'Synthetic',
      'accounts': [],
      'network': {'origins': []},
      'browser': false,
      'capabilities': [
        {
          'id': 'generic.section',
          'schema': 'elecon.generic.section',
          'schemaVersion': '1.0',
        },
      ],
    },
    'source': """export const capabilities={'generic.section':async(ctx,p)=>{
    if(p.block){ctx.log('info','started');await new Promise(r=>setTimeout(r,10000));}
    if(p.fail)throw elecon.errors.create('course_full');
    return {sectionId:'synthetic',title:p.nested?.value || 'ready'};
  }};""",
  }),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('invocation snapshots nested params and rejects invalid JSON', () {
    final params = <String, dynamic>{
      'nested': <String, dynamic>{
        'list': [1],
      },
    };
    final invocation = ScriptInvocation(
      packageId: 'synthetic',
      capability: 'test',
      params: params,
    );
    (params['nested']['list'] as List).add(2);
    expect(invocation.params['nested']['list'], [1]);
    expect(
      () => invocation.params['nested']['list'].add(3),
      throwsUnsupportedError,
    );
    expect(
      () => ScriptInvocation.snapshotParams({'value': double.nan}),
      throwsA(isA<JsonUnsupportedObjectError>()),
    );
    final cycle = <String, dynamic>{};
    cycle['self'] = cycle;
    expect(
      () => ScriptInvocation.snapshotParams(cycle),
      throwsA(isA<JsonCyclicError>()),
    );
  });

  test(
    'queued and default triggers freeze params; cancellation leaves next run intact',
    () async {
      final session = SessionController();
      addTearDown(session.dispose);
      final package = fixture();
      await session.installTrustedScript(
        package,
        approvedDigest: package.digest,
      );
      await session.selectTrustedScriptSchool(package.manifest.id);
      final started = Completer<void>();
      final cancel = ScriptRunCancellation();
      addTearDown(cancel.dispose);
      final blocker = session.runTrustedScript(
        package.manifest.id,
        'generic.section',
        params: {'block': true},
        cancellation: cancel,
        onLog: (_, message) {
          if (message == 'started' && !started.isCompleted) started.complete();
        },
      );
      await started.future.timeout(const Duration(seconds: 5));
      final directParams = <String, dynamic>{
        'nested': {'value': 'direct'},
      };
      final defaultParams = <String, dynamic>{
        'nested': {'value': 'default'},
      };
      final direct = session.runTrustedScript(
        package.manifest.id,
        'generic.section',
        params: directParams,
      );
      final selected = session.runCapability(
        'generic.section',
        params: defaultParams,
      );
      directParams['nested']['value'] = 'mutated';
      defaultParams['nested']['value'] = 'mutated';
      cancel.cancel();
      expect((await blocker).ok, isFalse);
      expect((await direct).data, containsPair('title', 'direct'));
      expect((await selected).data, containsPair('title', 'default'));
      final failed = await session.runCapability(
        'generic.section',
        params: {'fail': true},
      );
      expect(failed.reason, 'script_business_error');
      expect(failed.businessCode, 'synthetic.invocation:course_full');
      final wrongSource = await session.runTrustedScript(
        package.manifest.id,
        'generic.section',
        expectedDigest: 'stale',
      );
      expect(wrongSource.reason, 'script_not_authorized');
      final invalid = await session.runCapability(
        'generic.section',
        params: {'nan': double.nan},
      );
      expect(invalid.reason, 'input_invalid_request');
    },
  );
}
