import 'dart:async';
import 'dart:convert';

import 'package:elecon/core/scripts/execution.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/scripts/runtime.dart';
import 'package:elecon/session/capability_query.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

ScriptPackage fixture({
  String extra = '',
  int sdk = 19,
  String version = '1.0.0',
}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      'sdkVersion': sdk,
      'id': 'synthetic.execution',
      'schoolId': 'synthetic',
      'version': version,
      'name': 'Synthetic',
      'accounts': [],
      'network': {'origins': []},
      'browser': false,
      'home': [
        {'capability': 'generic.section', 'ttlSeconds': 60},
      ],
      'capabilities': [
        {
          'id': 'generic.section',
          'schema': 'elecon.generic.section',
          'schemaVersion': '1.0',
        },
      ],
    },
    'source':
        '''
let temporary = 'fresh';
export const capabilities = {'generic.section': async (ctx, p) => {
  if(p.block){ctx.log('info','started');await new Promise(r=>setTimeout(r,10000));}
  const e = ctx.execution;
  if (!e) return {sectionId:'test', title:'ordinary'};
  await e.state.set('data', {count:0});
  await e.register({id:'refresh',handler:'refresh',stateKey:'data'});
  temporary = 'initial-only';
  $extra
  if (p.timer) await e.schedule('refresh', ctx.now() + 1200);
  return {sectionId:'test', title:'initial'};
}};
export const handlers = {refresh: async function(ctx) {
  if (temporary !== 'fresh' || arguments.length !== 1) throw new Error('context leaked');
  const e = ctx.execution;
  const data = await e.state.get(e.stateKey);
  await e.state.set(e.stateKey, {count:data.count + 1});
  return {sectionId:'test', title:String(data.count + 1), trigger:e.trigger};
}};
''',
  }),
);

Matcher fails(String code) =>
    throwsA(isA<ScriptRunException>().having((e) => e.code, 'code', code));

Future<SessionController> sessionWith(ScriptPackage package) async {
  final session = SessionController();
  addTearDown(session.dispose);
  await session.installTrustedScript(package, approvedDigest: package.digest);
  await session.selectTrustedScriptSchool(package.manifest.id);
  return session;
}

Future<ScriptExecutionScope> scopeFor(SessionController session) async {
  final scope = (await session.openScriptExecutionScope('generic.section'))!;
  addTearDown(scope.dispose);
  return scope;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('registration and total storage budgets bound waiting work', () {
    final turn = ScriptExecutionTurn(
      ScriptExecutionMemory(),
      trigger: 'initial',
    );
    for (var i = 0; i < 4; i++) {
      turn.call('set', {'key': 'large$i', 'value': 'x' * 60000});
    }
    expect(
      () => turn.call('set', {'key': 'overflow', 'value': 'x' * 60000}),
      fails('execution_state_limit'),
    );
    for (var i = 0; i < 16; i++) {
      turn.call('register', {
        'id': 'r$i',
        'handler': 'refresh',
        'stateKey': 'large0',
      });
    }
    expect(
      () => turn.call('register', {
        'id': 'overflow',
        'handler': 'refresh',
        'stateKey': 'large0',
      }),
      fails('execution_registration_limit'),
    );
    turn.call('unregister', {'id': 'r0'});
    turn.call('register', {
      'id': 'replacement',
      'handler': 'refresh',
      'stateKey': 'large0',
    });
  });

  test(
    'cancelled and replaced appointments cannot deliver duplicate calls',
    () async {
      final session = await sessionWith(
        fixture(
          extra: """
      await e.schedule('refresh',ctx.now()+1200);
      await e.schedule('refresh',ctx.now()+60000);
    """,
        ),
      );
      final scope = await scopeFor(session);
      expect((await scope.run()).ok, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 1400));
      expect(scope.update!.result!.data, containsPair('title', 'initial'));
      expect(scope.hasScheduledCalls, isTrue);
      scope.cancel('refresh');
      expect(scope.hasScheduledCalls, isFalse);
      expect((await scope.invoke('refresh')).data, containsPair('title', '1'));
    },
  );

  test('storage and registration are data-only, bounded and staged', () {
    final memory = ScriptExecutionMemory();
    final turn = ScriptExecutionTurn(
      memory,
      trigger: 'initial',
      now: () => 10000,
    );
    expect(
      () => turn.call('get', {'key': 'missing'}),
      fails('execution_state_missing'),
    );
    final value = {
      'nested': [1],
    };
    turn.call('set', {'key': 'data', 'value': value});
    value['nested']!.add(2);
    expect(turn.call('get', {'key': 'data'}), {
      'nested': [1],
    });
    expect(memory.values, isEmpty);
    expect(
      () => turn.call('register', {
        'id': 'r',
        'handler': 'h',
        'stateKey': 'data',
        'params': {},
      }),
      fails('execution_invalid_request'),
    );
    turn.call('register', {'id': 'r', 'handler': 'h', 'stateKey': 'data'});
    for (final at in [10999, 86410001, 12000.5]) {
      expect(
        () => turn.call('schedule', {'id': 'r', 'at': at}),
        fails('execution_invalid_request'),
      );
    }
    turn.call('schedule', {'id': 'r', 'at': 12000});
    turn.call('schedule', {'id': 'r', 'at': 13000});
    expect(turn.schedules, {'r': 13000});
    turn.call('cancel', {'id': 'r'});
    expect(turn.registrations, contains('r'));
    expect(turn.schedules, {'r': null});
    expect(
      () => turn.call('set', {'key': 'big', 'value': 'x' * 65537}),
      fails('execution_state_limit'),
    );
    turn.commit(memory);
    expect(memory.registrations['r']!.handler, 'h');
    expect(
      () => turn.call('get', {'key': 'data'}),
      fails('invocation_cancelled'),
    );
    final next = ScriptExecutionTurn(memory, trigger: 'manual');
    next.call('unregister', {'id': 'r'});
    next.discard();
    expect(memory.registrations, contains('r'));
  });

  test(
    'named handler reads storage in a fresh engine; results do not overwrite query cache',
    () async {
      final session = await sessionWith(fixture());
      final scope = await scopeFor(session);
      expect((await scope.run()).ok, isTrue);
      expect((await scope.invoke('refresh')).data, containsPair('title', '1'));
      expect((await scope.invoke('refresh')).data, containsPair('title', '2'));
      expect(
        (await session.cachedCapability('generic.section'))!.data,
        containsPair('title', 'initial'),
      );
      expect(
        (await session.runCapability('generic.section')).data,
        containsPair('title', 'ordinary'),
      );
      scope.close();
      expect((await scope.invoke('refresh')).reason, 'script_cancelled');
      final replacement = await scopeFor(session);
      expect(
        (await replacement.invoke('refresh')).reason,
        'execution_registration_missing',
      );
    },
  );

  test('real timer executes once and returns to its owning scope', () async {
    final session = await sessionWith(fixture());
    final scope = await scopeFor(session);
    final done = Completer<void>();
    var deliveries = 0;
    scope.addListener(() {
      if (scope.update?.trigger == 'timer' && scope.update?.result != null) {
        deliveries++;
        expect(scope.update!.result!.data, containsPair('trigger', 'timer'));
        if (!done.isCompleted) done.complete();
      }
    });
    expect((await scope.run(params: {'timer': true})).ok, isTrue);
    expect(scope.hasScheduledCalls, isTrue);
    // Waiting on a timer does not occupy the global script queue.
    expect((await session.runCapability('generic.section')).ok, isTrue);
    await done.future.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(deliveries, 1);
    expect(scope.hasScheduledCalls, isFalse);
  });

  test(
    'failed output discards registrations, state and all pending appointments',
    () async {
      final session = await sessionWith(
        fixture(
          extra:
              "await e.schedule('refresh',ctx.now()+1200); return {wrong:true};",
        ),
      );
      final scope = await scopeFor(session);
      expect((await scope.run()).reason, 'schema_validation_failed');
      expect(scope.hasScheduledCalls, isFalse);
      expect(
        (await scope.invoke('refresh')).reason,
        'execution_registration_missing',
      );
    },
  );

  test(
    'JSON omissions, functions and registration parameter snapshots are rejected',
    () async {
      final session = await sessionWith(
        fixture(
          extra: '''
      for (const value of [()=>1, {value:undefined}, {toJSON(){return 1}}, new Date(), [undefined]]) {
        let rejected = false;
        try { await e.state.set('bad',value); } catch(err) { rejected=err.code==='execution_invalid_request'; }
        if(!rejected) throw new Error('invalid state accepted');
      }
      try { await e.register({id:'bad',handler:'refresh',stateKey:'data',params:{x:1}}); }
      catch(err) { if(err.code==='execution_invalid_request') return {sectionId:'test',title:'rejected'}; }
      throw new Error('parameter snapshot accepted');
    ''',
        ),
      );
      final scope = await scopeFor(session);
      expect((await scope.run()).data, containsPair('title', 'rejected'));
    },
  );

  test(
    'scope closure cancels a queued handler before any school code runs',
    () async {
      final session = await sessionWith(fixture());
      final scope = await scopeFor(session);
      expect((await scope.run()).ok, isTrue);
      final started = Completer<void>();
      final cancel = ScriptRunCancellation();
      final blocker = session.runTrustedScript(
        'synthetic.execution',
        'generic.section',
        params: {'block': true},
        cancellation: cancel,
        onLog: (_, message) {
          if (message == 'started' && !started.isCompleted) started.complete();
        },
      );
      await started.future.timeout(const Duration(seconds: 5));
      final pending = scope.invoke('refresh');
      scope.close();
      cancel.cancel();
      expect((await blocker).ok, isFalse);
      expect((await pending).reason, 'script_cancelled');
    },
  );

  test(
    'foreground, data identity and source changes revoke scoped registrations',
    () async {
      final session = await sessionWith(fixture());
      var scope = await scopeFor(session);
      await scope.run(params: {'timer': true});
      session.scriptAppForeground = false;
      expect(scope.isClosed, isTrue);
      expect(scope.hasScheduledCalls, isFalse);
      expect(await session.openScriptExecutionScope('generic.section'), isNull);
      session.scriptAppForeground = true;
      scope = await scopeFor(session);
      await scope.run();
      final updated = fixture(version: '1.0.1');
      await session.installTrustedScript(
        updated,
        approvedDigest: updated.digest,
      );
      expect(scope.isClosed, isTrue);
      expect((await scope.invoke('refresh')).ok, isFalse);
      scope = await scopeFor(session);
      await scope.run();
      session.logout();
      expect(scope.isClosed, isTrue);
    },
  );

  test(
    'SDK18 stays one-shot and expired appointments never enter QuickJS',
    () async {
      final session = await sessionWith(fixture(sdk: 18));
      expect(await session.openScriptExecutionScope('generic.section'), isNull);
      expect(
        (await session.runCapability('generic.section')).data,
        containsPair('title', 'ordinary'),
      );
      final updated = fixture(version: '1.0.1');
      await session.installTrustedScript(
        updated,
        approvedDigest: updated.digest,
      );
      final turn = ScriptExecutionTurn(
        ScriptExecutionMemory(),
        trigger: 'timer',
        deadline: 1,
      );
      expect(
        (await session.runTrustedScript(
          updated.manifest.id,
          'generic.section',
          execution: turn,
        )).reason,
        'execution_missed',
      );
    },
  );

  test(
    'default and pinned query facades forward cancellation to the real queue',
    () async {
      final package = fixture();
      final session = await sessionWith(package);
      for (final source in [
        null,
        CapabilitySource(
          packageId: package.manifest.id,
          digest: package.digest,
        ),
      ]) {
        final cancellation = ScriptRunCancellation()..cancel();
        final result = await CapabilityQueries(
          session,
          source: source,
        ).runCapability('generic.section', cancellation: cancellation);
        expect(result.reason, 'script_cancelled');
      }
    },
  );
}
