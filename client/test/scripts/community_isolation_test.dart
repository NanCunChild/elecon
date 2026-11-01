import 'dart:async';
import 'dart:convert';

import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'service failure and cancellation preserve school login, queued queries and cached timetable',
    () async {
      final package = ScriptPackage.parse(
        jsonEncode({
          'format': 'elecon-script/1',
          'manifest': {
            'sdkVersion': 4,
            'id': 'synthetic-base',
            'schoolId': 'synthetic-school',
            'version': '1.0.0',
            'name': 'Synthetic',
            'network': {'origins': []},
            'browser': false,
            'capabilities': [
              for (final cap in [
                'generic.section',
                'schedule.week',
                'forum.session',
              ])
                {'id': cap, 'schema': 'elecon.$cap', 'schemaVersion': '1.0'},
            ],
            'home': [
              {'capability': 'schedule.week', 'ttlSeconds': 900},
            ],
          },
          'source': '''export const capabilities={
        'generic.section':async ctx=>{await ctx.credentials.set('school','SYNTHETIC');return {sectionId:'school',title:'Signed in'}},
        'schedule.week':async ctx=>{if((await ctx.credentials.get('school'))?.value!=='SYNTHETIC')throw new Error('school session lost');return {term:'synthetic-term',week:1,days:[]}},
        'forum.session':async(ctx,p)=>{
          if(p.operation==='status'){const error=new Error('source_response_invalid');error.code='source_response_invalid';throw error;}
          ctx.log('info','synthetic_service_waiting');
          await new Promise(resolve=>setTimeout(resolve,10000));
          await ctx.credentials.delete('school');
          return {serviceId:'synthetic-forum',serviceName:'Synthetic forum',status:'signedOut'};
        }
      };''',
        }),
      );
      final session = SessionController();
      addTearDown(session.dispose);
      await session.installTrustedScript(
        package,
        approvedDigest: package.digest,
      );
      await session.selectTrustedScriptSchool(package.manifest.id);
      expect(
        (await session.runTrustedScript(
          package.manifest.id,
          'generic.section',
        )).ok,
        isTrue,
      );
      expect((await session.runCapability('schedule.week')).ok, isTrue);
      final cached = await session.cachedCapability('schedule.week');
      expect(cached, isNotNull);
      final generation = session.trustedScriptViewGeneration;
      final failed = await session.runTrustedScript(
        package.manifest.id,
        'forum.session',
        params: {'operation': 'status'},
      );
      expect(failed.reason, 'source_response_invalid');
      final started = Completer<void>();
      final cancellation = ScriptRunCancellation();
      addTearDown(cancellation.dispose);
      final service = session.runTrustedScript(
        package.manifest.id,
        'forum.session',
        params: {'operation': 'login'},
        cancellation: cancellation,
        onLog: (_, message) {
          if (message == 'synthetic_service_waiting' && !started.isCompleted) {
            started.complete();
          }
        },
      );
      await started.future.timeout(const Duration(seconds: 5));
      final schoolQuery = session.runTrustedScript(
        package.manifest.id,
        'schedule.week',
        params: {'week': 1},
      );
      cancellation.cancel();
      expect((await service).ok, isFalse);
      expect((await schoolQuery).ok, isTrue);
      expect(session.trustedScriptViewGeneration, generation);
      expect(session.isLoggedIn, isTrue);
      expect(
        (await session.cachedCapability('schedule.week'))?.data,
        cached!.data,
      );
      expect(
        (await session.cachedCapability('schedule.week'))?.fetchedAt,
        cached.fetchedAt,
      );
    },
  );
}
