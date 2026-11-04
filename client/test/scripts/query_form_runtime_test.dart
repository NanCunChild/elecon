import 'dart:convert';

import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/scripts/query_filters.dart';
import 'package:elecon/core/scripts/runtime.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
