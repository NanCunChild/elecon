import 'dart:async';
import 'dart:convert';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/ui/home/energy_climate_sections.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'energy_climate_sections_test.dart' as ui;
import 'support/climate_fixture.dart';

void main() {
  testWidgets(
    'disposed climate page cancels a queued command before execution',
    (tester) async {
      final raw =
          jsonDecode(syntheticClimatePackage().encode())
              as Map<String, dynamic>;
      raw['manifest']['network'] = {'origins': <String>[]};
      raw['source'] =
          """export const capabilities={
      'profile.me':async(ctx,p)=>{
        if(p.block){ctx.log('info','review-blocker-started');await new Promise(()=>{});}
        return {};
      },
      'climate.devices':async()=>({items:[${jsonEncode(syntheticClimateDevice())}]}),
      'climate.status':async(ctx,p)=>({deviceId:p.deviceId,power:false}),
      'climate.command':async(ctx)=>{
        await ctx.credentials.set('review-command-marker','executed');
        return {status:'accepted'};
      }
    };""";
      final package = ScriptPackage.parse(jsonEncode(raw));
      final session = SessionController();
      addTearDown(session.dispose);
      await tester.runAsync(() async {
        await session.installTrustedScript(
          package,
          approvedDigest: package.digest,
        );
        await session.selectTrustedScriptSchool(package.manifest.id);
        expect(
          (await session.runCapability('profile.me', interactive: false)).ok,
          isTrue,
        );
      });
      await tester.pumpWidget(ui.app(session, const ClimateSection()));
      await ui.until(
        tester,
        () =>
            ui.powerSwitch().evaluate().isNotEmpty &&
            tester.widget<SwitchListTile>(ui.powerSwitch()).onChanged != null,
      );

      final cancelBlocker = ScriptRunCancellation();
      addTearDown(cancelBlocker.dispose);
      var started = false;
      await tester.runAsync(() async {
        unawaited(
          session.runTrustedScript(
            package.manifest.id,
            'profile.me',
            params: {'block': true},
            interactive: false,
            cancellation: cancelBlocker,
            onLog: (_, message) {
              if (message == 'review-blocker-started') started = true;
            },
          ),
        );
      });
      await ui.until(tester, () => started);
      final before = session.credentialCount;
      tester.widget<SwitchListTile>(ui.powerSwitch()).onChanged!(true);
      await tester.pump();
      expect(
        session.credentialCount,
        before,
        reason: 'command remains behind blocker',
      );
      await tester.pumpWidget(ui.app(session, const SizedBox()));
      expect(find.byType(ClimateSection), findsNothing);
      cancelBlocker.cancel();
      var drained = false;
      unawaited(
        session.runCapability('profile.me', interactive: false).then((_) {
          drained = true;
        }),
      );
      await ui.until(tester, () => drained);
      expect(
        session.credentialCount,
        before,
        reason: 'No command marker may be written after page disposal.',
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
