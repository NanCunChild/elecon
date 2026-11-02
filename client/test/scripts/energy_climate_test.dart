// Synthetic HTTP/devices only; ADR-040 core and real bundled QuickJS regression.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:elecon/core/credential/secure_store.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/scripts/runtime.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon_contract/output_validator_registry.dart';
import 'package:flutter_test/flutter_test.dart';

const endpoint = 'https://device.example.invalid/command';
final deviceId = List.filled(15, '0').join();
Map<String, dynamic> commandParams() => {
  'deviceId': deviceId,
  'command': 'power',
  'settings': {'power': true},
};
Map<String, dynamic> packageJson(String source) => {
  'format': 'elecon-script/1',
  'manifest': {
    'sdkVersion': 5,
    'id': 'school.synthetic',
    'version': '1.0.0',
    'schoolId': 'synthetic',
    'name': 'Synthetic school',
    'network': {
      'origins': ['https://device.example.invalid'],
    },
    'browser': false,
    'capabilities': [
      {
        'id': 'climate.command',
        'schema': 'elecon.climate.command',
        'schemaVersion': '1.0',
      },
    ],
  },
  'source': source,
};
ScriptCredentials credentials(ScriptPackage package) => ScriptCredentials(
  store: CredentialStore(store: InMemorySecureStore(releaseMode: false)),
  schoolId: package.manifest.schoolId,
  scriptId: package.manifest.id,
  sdkVersion: package.manifest.sdkVersion,
);
Map<String, Object?> response(String url, Object data, {int status = 200}) => {
  'url': url,
  'status': status,
  'headers': <String, List<String>>{},
  'body': jsonEncode(data),
};
const validSource =
    "export const capabilities={'climate.command':async(ctx)=>{await ctx.fetch('$endpoint',{method:'POST',redirect:'error',body:'{}'});return {status:'accepted'}}};";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('ordinary commands need no action declaration in supported SDKs', () {
    for (var sdk = 1; sdk <= 7; sdk++) {
      final raw = packageJson(validSource);
      (raw['manifest'] as Map)['sdkVersion'] = sdk;
      expect(ScriptPackage.parse(jsonEncode(raw)).requiresUpdate, isFalse);
      for (final actions in [
        [],
        [
          {'capability': 'climate.command', 'method': 'POST', 'url': endpoint},
        ],
      ]) {
        (raw['manifest'] as Map)['actions'] = actions;
        expect(
          () => ScriptPackage.parse(jsonEncode(raw)),
          throwsFormatException,
        );
      }
    }
    final raw = packageJson(validSource);
    (raw['manifest'] as Map)['home'] = [
      {'capability': 'climate.command', 'ttlSeconds': 30},
    ];
    expect(() => ScriptPackage.parse(jsonEncode(raw)), throwsFormatException);
  });
  test(
    'old energy usage validator is preserved and new fields are validated',
    () {
      final old = outputValidatorFor('elecon.energy.usage', '1.0')!;
      final current = outputValidatorFor('elecon.energy.usage', '1.1')!;
      expect(
        old({
          'items': [
            {'reading': 10, 'meterId': 42},
          ],
        }),
        isTrue,
      );
      expect(
        current({
          'items': [
            {'reading': 10, 'meterId': 42},
          ],
        }),
        isFalse,
      );
      expect(
        current({
          'items': [
            {
              'reading': 10,
              'previousReading': 8,
              'usage': 2,
              'meterId': 'synthetic',
            },
          ],
        }),
        isTrue,
      );
    },
  );
  test('restored action packages cannot evaluate source', () async {
    final raw = packageJson("throw Error('must not evaluate');");
    (raw['manifest'] as Map)['actions'] = [];
    final retired = ScriptPackage.restore(jsonEncode(raw));
    expect(retired.requiresUpdate, isTrue);
    expect(jsonDecode(retired.encode())['manifest']['actions'], []);
    await expectLater(
      const TrustedScriptRuntime().run(
        package: retired,
        capability: 'climate.command',
        credentials: credentials(retired),
        fetch: (_, _) async => throw StateError('must not send'),
      ),
      throwsA(
        isA<ScriptRunException>().having(
          (e) => e.code,
          'code',
          'script_update_required',
        ),
      ),
    );
  });
  test('commands share ordinary fetch and can query after sending', () async {
    final p = ScriptPackage.parse(
      jsonEncode(
        packageJson(
          "export const capabilities={'climate.command':async(ctx)=>{await ctx.fetch('$endpoint',{method:'POST',redirect:'error'});await ctx.fetch('$endpoint/state');return {status:'accepted'}}};",
        ),
      ),
    );
    final calls = <String>[];
    final result = await const TrustedScriptRuntime().run(
      package: p,
      capability: 'climate.command',
      credentials: credentials(p),
      fetch: (url, init) async {
        calls.add('${init['method'] ?? 'GET'} $url');
        return response(url, {});
      },
    );
    expect(result, {'status': 'accepted'});
    expect(calls, ['POST $endpoint', 'GET $endpoint/state']);
  });
  test('ordinary commands retain network authorization', () async {
    final p = ScriptPackage.parse(
      jsonEncode(
        packageJson(
          "export const capabilities={'climate.command':async ctx=>{await ctx.fetch('https://other.example.invalid/command',{method:'POST'});return {status:'accepted'}}};",
        ),
      ),
    );
    var calls = 0;
    await expectLater(
      const TrustedScriptRuntime().run(
        package: p,
        capability: 'climate.command',
        credentials: credentials(p),
        fetch: (url, _) async {
          calls++;
          return response(url, {});
        },
      ),
      throwsA(isA<ScriptRunException>()),
    );
    expect(calls, 0);
  });
  test('timeout and cancellation do not retry an ordinary command', () async {
    for (final cancel in [false, true]) {
      final p = ScriptPackage.parse(jsonEncode(packageJson(validSource)));
      var active = true, calls = 0;
      final started = Completer<void>();
      final pending = const TrustedScriptRuntime().run(
        package: p,
        capability: 'climate.command',
        credentials: credentials(p),
        isActive: () => active,
        wallTimeout: const Duration(milliseconds: 200),
        fetch: (url, _) async {
          calls++;
          started.complete();
          await Future<void>.delayed(const Duration(milliseconds: 500));
          return response(url, {});
        },
      );
      final assertion = expectLater(
        pending,
        throwsA(isA<ScriptRunException>()),
      );
      await started.future;
      if (cancel) active = false;
      await assertion;
      expect(calls, 1);
    }
  });
  test('legacy adapter command remains unavailable', () async {
    final session = SessionController();
    addTearDown(session.dispose);
    expect(
      (await session.runAdapterCapability(
        adapterId: 'synthetic',
        capability: 'climate.command',
      )).reason,
      'legacy_command_unavailable',
    );
  });

  group('actual undergraduate package in QuickJS', () {
    late ScriptPackage school;
    setUpAll(() async {
      final result = await Process.run('npm', [
        'run',
        'scripts:xidian',
        '-w',
        'tools',
      ], workingDirectory: '..');
      expect(result.exitCode, 0, reason: '${result.stderr}');
      school = ScriptPackage.parse(
        await File(
          '../school-scripts/xidian/dist/school-xidian-undergraduate.elecon.json',
        ).readAsString(),
      );
    });
    test(
      'AES/signature requests and normalized meter history execute in QuickJS',
      () async {
        final creds = credentials(school);
        for (final service in ['ids', 'energy']) {
          creds.set(
            service,
            jsonEncode({
              'version': 1,
              'service': service,
              'cookies': [],
              'data': service == 'energy'
                  ? {'nodeId': 'SYNTHETIC-NODE'}
                  : <String, Object?>{},
            }),
            namespace: 'xidian.auth',
          );
        }
        var signatures = 0, reads = 0;
        final data = await const TrustedScriptRuntime().run(
          package: school,
          capability: 'energy.usage',
          params: {
            'meterId': 'SYNTHETIC-WATER',
            'from': '2026-03-01T00:00:00+08:00',
            'to': '2026-03-31T23:59:59+08:00',
          },
          credentials: creds,
          htmlStdlib: await File('assets/stdlib/html.bundle.js').readAsString(),
          fetch: (url, init) async {
            final uri = Uri.parse(url);
            if (uri.path.endsWith('GetSignature')) {
              signatures++;
              return response(url, {
                'data': {'timestamp': '123', 'signature': 'SYNTHETIC-SIGN'},
              });
            }
            expect((init['headers'] as Map)['signature'], 'SYNTHETIC-SIGN');
            // Independently decrypt with Node/OpenSSL rather than reusing the school AES.
            final encoded = Uri.decodeComponent(
              uri.queryParameters['content']!,
            );
            final decoded = await Process.run('node', [
              '--input-type=module',
              '-e',
              "import{createDecipheriv}from'node:crypto';const k=Buffer.from('1234567812345678'),c=createDecipheriv('aes-128-cbc',k,k);process.stdout.write(Buffer.concat([c.update(Buffer.from(process.argv[1],'base64')),c.final()]).toString())",
              encoded,
            ]);
            expect(decoded.exitCode, 0);
            final payload = jsonDecode(decoded.stdout as String) as Map;
            if (uri.path.endsWith('H5QueryMeterList')) {
              expect(payload, {'NodeID': 'SYNTHETIC-NODE'});
              return response(url, {
                'ResData': {
                  'rows': [
                    {'MetID': 'SYNTHETIC-WATER', 'MediumCode': '1'},
                  ],
                },
              });
            }
            expect(payload, {
              'MetID': 'SYNTHETIC-WATER',
              'ReadTimeS': '2026-03-01',
              'ReadTimeE': '2026-03-31',
              'ReadNum': '',
            });
            reads++;
            return response(url, {
              'ResData': {
                'rows': [
                  {
                    'ReadTime': '2026-03-30 08:00:00',
                    'ReadNum': '2.5',
                    'StartNum': '10',
                    'EndNum': '12.5',
                  },
                ],
              },
            });
          },
        );
        expect(signatures, 2);
        expect(reads, 1);
        expect((data as Map)['items'], [
          {
            'meterId': 'SYNTHETIC-WATER',
            'type': 'water',
            'unit': 'm³',
            'readAt': '2026-03-30T00:00:00.000Z',
            'usage': 2.5,
            'reading': 12.5,
            'previousReading': 10,
          },
        ]);
      },
    );
    test(
      'actual device command preserves identity and sends exactly one ordinary POST',
      () async {
        final creds = credentials(school);
        creds.set(
          'device',
          jsonEncode({'deviceId': deviceId, 'label': 'Synthetic device'}),
          namespace: 'xidian.climate',
        );
        final params = commandParams();
        var calls = 0;
        final result = await const TrustedScriptRuntime().run(
          package: school,
          capability: 'climate.command',
          params: params,
          credentials: creds,
          htmlStdlib: await File('assets/stdlib/html.bundle.js').readAsString(),
          fetch: (url, init) async {
            calls++;
            expect(url, 'https://gxkt.juhaolian.cn/api/device/direct/command');
            expect(init['redirect'], 'error');
            expect(jsonDecode(init['body'] as String), {
              'imei': deviceId,
              'switchStatus': 1,
            });
            return response(url, {'success': true});
          },
        );
        expect(result, {'status': 'accepted'});
        expect(calls, 1);
      },
    );
    test(
      'actual binding input validates state and persists in the allowed credential model',
      () async {
        final creds = credentials(school);
        var reads = 0;
        final data = await const TrustedScriptRuntime().run(
          package: school,
          capability: 'climate.devices',
          params: const {'configure': true},
          credentials: creds,
          htmlStdlib: await File('assets/stdlib/html.bundle.js').readAsString(),
          inputCall: (_) async => {
            'deviceId': deviceId,
            'label': 'Synthetic room',
          },
          fetch: (url, init) async {
            reads++;
            expect(Uri.parse(url).queryParameters['imei'], deviceId);
            return response(url, {
              'success': true,
              'result': {
                'imei': deviceId,
                'switchStatus': 0,
                'runMode': 2,
                'windSpeed': 0,
                'tempSet': 26,
              },
            });
          },
        );
        expect(reads, 1);
        expect(((data as Map)['items'] as List).length, 1);
        final saved = creds.get('device', namespace: 'xidian.climate')!;
        expect(saved['type'], 'query');
        expect(jsonDecode(saved['value'] as String), {
          'deviceId': deviceId,
          'label': 'Synthetic room',
        });
      },
    );
  });
}
