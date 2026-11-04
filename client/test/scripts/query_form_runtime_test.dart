import 'dart:async';
import 'dart:convert';

import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/scripts/query_filters.dart';
import 'package:elecon/core/scripts/runtime.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/school_fixture.dart';

ScriptPackage package({String version = '2.0', String? source}) =>
    ScriptPackage.parse(
      jsonEncode({
        'format': 'elecon-script/1',
        'manifest': {
          'sdkVersion': 17,
          'accounts': [],
          'id': 'synthetic.forms',
          'schoolId': 'synthetic',
          'version': '1.0.0',
          'name': 'Synthetic query forms',
          'network': {'origins': []},
          'browser': false,
          'capabilities': [
            {
              'id': 'query.controls',
              'schema': 'elecon.query.controls',
              'schemaVersion': version,
            },
            {
              'id': 'grades.list',
              'schema': 'elecon.grades.list',
              'schemaVersion': '1.1',
            },
          ],
        },
        'source':
            source ??
            '''export const capabilities={
        'query.controls':async(ctx,p)=>{ctx.log('info','executed');return {target:p.target,title:'Synthetic',submitLabel:'Search',controls:[]};},
        'grades.list':async(ctx,p)=>{ctx.log('info','executed');return {term:'synthetic-term',items:[],echo:p.filters};}
      };''',
      }),
    );

Future<Object?> run(
  ScriptPackage p,
  String capability,
  Map<String, dynamic> params, {
  void Function(String, String)? onLog,
}) => const TrustedScriptRuntime().run(
  package: p,
  capability: capability,
  params: params,
  credentials: ScriptCredentials(
    store: CredentialStore(),
    schoolId: p.manifest.schoolId,
    scriptId: p.manifest.id,
    sdkVersion: p.manifest.sdkVersion,
  ),
  fetch: (_, _) async => throw StateError('No network in fixture'),
  onLog: onLog,
);

Matcher code(String expected) =>
    isA<ScriptRunException>().having((e) => e.code, 'code', expected);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'typed values preserve zero/false and bound map size and reserved ids',
    () {
      expect(
        isQueryFilterMap({
          'seats': 0,
          'accessible': false,
          'types': ['a', 'b'],
          'time': {'start': '08:00', 'end': '10:00'},
        }),
        isTrue,
      );
      for (final value in [
        {'constructor': 'bad'},
        {'prototype': 'bad'},
        {'__proto__': 'bad'},
        {'unknown': null},
        {'number': double.infinity},
        {
          'array': ['a', 'a'],
        },
        {
          'array': [true],
        },
        {
          'nested': {'url': 'https://synthetic.invalid'},
        },
        {
          'time': {'start': '09:00', 'end': '08:00'},
        },
        {for (var i = 0; i < 33; i++) 'field$i': i},
        {for (var i = 0; i < 32; i++) 'field$i': '界' * 512},
      ]) {
        expect(isQueryFilterMap(value), isFalse);
      }
    },
  );

  test(
    'real QuickJS receives independent arbitrary fields and current draft',
    () async {
      final p = package();
      final filters = {
        'firstNumber': 0,
        'secondNumber': 42,
        'flag': false,
        'choices': ['x'],
      };
      final metadata =
          await run(p, 'query.controls', {
                'target': 'grades.list',
                'current': filters,
                'changed': 'firstNumber',
              })
              as Map;
      expect(metadata['controls'], isEmpty);
      final output = await run(p, 'grades.list', {'filters': filters}) as Map;
      expect(output['echo'], filters);
    },
  );

  test(
    'invalid metadata and filters reject before executing school code',
    () async {
      final p = package();
      final logs = <String>[];
      for (final params in [
        {'target': 'climate.command'},
        {'target': 'classroom.available'}, // absent in this package
        {'target': 'grades.list', 'configure': true},
        {
          'target': 'grades.list',
          'current': {'x': null},
        },
        {
          'target': 'grades.list',
          'current': {'x': double.nan},
        },
        {'target': 'grades.list', 'changed': 'constructor'},
      ]) {
        await expectLater(
          run(p, 'query.controls', params, onLog: (_, m) => logs.add(m)),
          throwsA(code('input_invalid_request')),
        );
      }
      await expectLater(
        run(p, 'grades.list', {
          'filters': {
            'nested': {'capability': 'climate.command'},
          },
        }, onLog: (_, m) => logs.add(m)),
        throwsA(code('input_invalid_request')),
      );
      for (final value in [
        double.infinity,
        double.negativeInfinity,
        double.nan,
      ]) {
        await expectLater(
          run(p, 'grades.list', {
            'filters': {'number': value},
          }, onLog: (_, m) => logs.add(m)),
          throwsA(code('input_invalid_request')),
        );
      }
      expect(logs, isEmpty);
    },
  );

  test(
    'metadata target and byte budget enforced beyond open query outputs',
    () async {
      final mismatched = package(
        source:
            "export const capabilities={'query.controls':async()=>({target:'classroom.available',title:'Synthetic',submitLabel:'Search',controls:[]})};",
      );
      await expectLater(
        run(mismatched, 'query.controls', {'target': 'grades.list'}),
        throwsA(code('schema_validation_failed')),
      );
      final oversized = package(
        source:
            "export const capabilities={'query.controls':async()=>({target:'grades.list',title:'x'.repeat(128*1024),submitLabel:'Search',controls:[]})};",
      );
      await expectLater(
        run(oversized, 'query.controls', {'target': 'grades.list'}),
        throwsA(code('output_limit')),
      );
    },
  );

  test(
    '2.1 passes requested field ids to real QuickJS and accepts deferred output',
    () async {
      final p = package(
        version: '2.1',
        source: '''export const capabilities={
          'query.controls': async(ctx,p)=>({
            target:p.target,title:'Synthetic',submitLabel:'Search',
            controls:(p.load || ['optionalField']).map(id=>({
              id,kind:'select',label:id,options:[],deferred:!p.load
            }))
          })
        };''',
      );
      final base =
          await run(p, 'query.controls', {'target': 'grades.list'}) as Map;
      expect(base['controls'].single['deferred'], isTrue);
      final requested = [for (var i = 0; i < 32; i++) 'field$i'];
      final supplement =
          await run(p, 'query.controls', {
                'target': 'grades.list',
                'load': requested,
                'current': {'prerequisite': false},
              })
              as Map;
      expect(
        (supplement['controls'] as List).map((field) => field['id']),
        requested,
      );
      expect(
        (supplement['controls'] as List).every(
          (field) => field['deferred'] == false,
        ),
        isTrue,
      );
    },
  );

  test('load is bounded, unique and exclusive to query.controls 2.1', () async {
    final logs = <String>[];
    for (final version in ['1.0', '2.0']) {
      await expectLater(
        run(
          package(version: version),
          'query.controls',
          {
            'target': 'grades.list',
            'load': ['optionalField'],
          },
          onLog: (_, message) => logs.add(message),
        ),
        throwsA(code('input_invalid_request')),
      );
    }
    final p = package(version: '2.1');
    for (final load in <Object?>[
      null,
      [],
      'field',
      [1],
      ['same', 'same'],
      ['constructor'],
      ['__proto__'],
      ['invalid id'],
      [for (var i = 0; i < 33; i++) 'field$i'],
    ]) {
      await expectLater(
        run(p, 'query.controls', {
          'target': 'grades.list',
          'load': load,
        }, onLog: (_, message) => logs.add(message)),
        throwsA(code('input_invalid_request')),
      );
    }
    expect(logs, isEmpty);
  });

  test(
    '2.1 retains target, byte budgets and independent filters protection',
    () async {
      final p = package(version: '2.1');
      final filters = {'number': 0, 'flag': false};
      expect(
        (await run(p, 'grades.list', {'filters': filters}) as Map)['echo'],
        filters,
      );
      final logs = <String>[];
      for (final invalid in [
        {'field': null},
        {'field': double.infinity},
        {for (var i = 0; i < 32; i++) 'field$i': '界' * 512},
      ]) {
        await expectLater(
          run(p, 'grades.list', {
            'filters': invalid,
          }, onLog: (_, message) => logs.add(message)),
          throwsA(code('input_invalid_request')),
        );
        await expectLater(
          run(p, 'query.controls', {
            'target': 'grades.list',
            'current': invalid,
          }, onLog: (_, message) => logs.add(message)),
          throwsA(code('input_invalid_request')),
        );
      }
      expect(logs, isEmpty);
      for (final entry in {
        'schema_validation_failed':
            "{target:'classroom.available',title:'Synthetic',submitLabel:'Search',controls:[]}",
        'output_limit':
            "{target:'grades.list',title:'x'.repeat(128*1024),submitLabel:'Search',controls:[]}",
      }.entries) {
        await expectLater(
          run(
            package(
              version: '2.1',
              source:
                  "export const capabilities={'query.controls':async()=>(${entry.value})};",
            ),
            'query.controls',
            {'target': 'grades.list'},
          ),
          throwsA(code(entry.key)),
        );
      }
    },
  );

  test(
    'old query.controls packages retain old domain input behavior',
    () async {
      final old = package(version: '1.0');
      final output =
          await run(old, 'grades.list', {
                'filters': {
                  'legacyExtension': {'value': 'unchanged'},
                },
              })
              as Map;
      expect(output['echo'], {
        'legacyExtension': {'value': 'unchanged'},
      });
    },
  );

  test(
    'cancelling optional metadata releases the session queue before its JS promise completes',
    () async {
      final school = testSchool(schoolId: 'synthetic');
      final session = SessionController(initialSchools: [school]);
      addTearDown(session.dispose);
      session.selectSchool(school);
      final p = package(
        version: '2.1',
        source: '''export const capabilities={
          'query.controls':async(ctx,p)=>{
            ctx.log('info','waiting');
            await new Promise(()=>{});
          },
          'grades.list':async()=>({term:'synthetic',items:[]})
        };''',
      );
      await session.installTrustedScript(p, approvedDigest: p.digest);
      final ready = Completer<void>();
      final cancellation = ScriptRunCancellation();
      final pending = session.runTrustedScript(
        p.manifest.id,
        'query.controls',
        expectedDigest: p.digest,
        interactive: false,
        cancellation: cancellation,
        params: {
          'target': 'grades.list',
          'load': ['optional'],
        },
        onLog: (_, message) {
          if (message == 'waiting' && !ready.isCompleted) ready.complete();
        },
      );
      addTearDown(() async {
        cancellation.cancel();
        try {
          await pending;
        } finally {
          cancellation.dispose();
        }
      });
      await ready.future.timeout(const Duration(seconds: 5));
      cancellation.cancel();
      // This is a deadlock bound, not a performance target: the optional JS
      // promise never resolves and the ordinary runtime budget is 35 seconds.
      final query = await session
          .runTrustedScript(
            p.manifest.id,
            'grades.list',
            expectedDigest: p.digest,
            interactive: false,
          )
          .timeout(const Duration(seconds: 1));
      expect(query.ok, isTrue);
      expect((await pending).ok, isFalse);
    },
  );
}
