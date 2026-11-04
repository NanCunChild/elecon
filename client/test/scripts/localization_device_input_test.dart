import 'dart:async';
import 'dart:convert';

import 'package:elecon/core/scripts/device_input.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('late revoked picker cannot revoke its replacement lease', () async {
    final lease = ScriptSystemInputLease();
    final oldValue = Completer<void>();
    final newValue = Completer<void>();
    final old = lease.run(() => oldValue.future);
    final oldRejected = expectLater(
      old,
      throwsA(
        isA<ScriptDeviceInputException>().having(
          (error) => error.code,
          'code',
          'invocation_cancelled',
        ),
      ),
    );
    lease.revoke();
    final replacement = lease.run(() => newValue.future);
    lease.foreground = false;
    oldValue.complete();
    await oldRejected;
    expect(lease.active, isTrue);
    expect(lease.executionAllowed, isTrue);
    lease.foreground = true;
    newValue.complete();
    await replacement;
    expect(lease.active, isFalse);
    expect(lease.executionAllowed, isTrue);
  });

  test(
    'locale cancellation releases the run queue and preserves a new picker',
    () async {
      final package = ScriptPackage.parse(
        jsonEncode({
          'format': 'elecon-script/1',
          'manifest': {
            'sdkVersion': 13,
            'id': 'synthetic.locale.picker',
            'schoolId': 'synthetic',
            'version': '1.0.0',
            'name': 'Synthetic locale picker',
            'browser': false,
            'network': {'origins': []},
            'deviceInputs': ['image'],
            'accounts': [],
            'capabilities': [
              {
                'id': 'notice.list',
                'schema': 'elecon.notice.list',
                'schemaVersion': '1.1',
              },
            ],
          },
          'source':
              '''export const capabilities={'notice.list':async(ctx,params)=>{
        if(params.pick) await ctx.ui.pickImage();
        return {items:[],sourceSystem:ctx.locale};
      }};''',
        }),
      );
      final session = SessionController();
      addTearDown(session.dispose);
      await session.installTrustedScript(
        package,
        approvedDigest: package.digest,
      );
      await session.selectTrustedScriptSchool(package.manifest.id);
      final oldValue = Completer<Object?>();
      final oldOpened = Completer<void>();
      final oldFinished = Completer<void>();
      final newValue = Completer<Object?>();
      final newOpened = Completer<void>();
      var calls = 0;
      late bool Function() newValid;
      session.scriptDeviceInputPresenter = (_, _, valid, lease) {
        calls++;
        if (calls == 1) {
          final pending = lease.run(() {
            oldOpened.complete();
            return oldValue.future;
          });
          unawaited(
            pending.then<void>(
              (_) => oldFinished.complete(),
              onError: (Object _) => oldFinished.complete(),
            ),
          );
          return pending;
        }
        return lease.run(() {
          newValid = valid;
          newOpened.complete();
          return newValue.future;
        });
      };
      final old = session.runTrustedScript(
        package.manifest.id,
        'notice.list',
        params: {'pick': true},
      );
      await oldOpened.future.timeout(const Duration(seconds: 5));
      expect(session.scriptSystemInputPending, isTrue);
      session.scriptLocale = 'fa';
      expect(session.scriptSystemInputPending, isFalse);
      expect((await old.timeout(const Duration(seconds: 5))).ok, isFalse);

      final replacement = session.runTrustedScript(
        package.manifest.id,
        'notice.list',
        params: {'pick': true},
      );
      await newOpened.future.timeout(const Duration(seconds: 5));
      session.scriptAppForeground = false;
      expect(newValid(), isTrue);
      oldValue.complete(null);
      await oldFinished.future.timeout(const Duration(seconds: 5));
      expect(session.scriptSystemInputPending, isTrue);
      expect(newValid(), isTrue);
      session.scriptAppForeground = true;
      newValue.complete(null);
      final result = await replacement.timeout(const Duration(seconds: 5));
      expect(result.ok, isTrue, reason: result.reason);
      expect((result.data as Map)['sourceSystem'], 'fa');
      expect(session.scriptSystemInputPending, isFalse);
      final next = await session.runTrustedScript(
        package.manifest.id,
        'notice.list',
      );
      expect(next.ok, isTrue, reason: next.reason);
      expect((next.data as Map)['sourceSystem'], 'fa');
      expect(calls, 2);
    },
  );
}
