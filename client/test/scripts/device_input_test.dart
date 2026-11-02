import 'dart:typed_data';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:elecon/core/credential/secure_store.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/scripts/device_input.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/scripts/runtime.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:elecon/ui/scripts/script_device_input_page.dart';
import 'package:flutter_test/flutter_test.dart';

import '../utils/test_utils.dart' show repoPath;

final fixture =
    jsonDecode(
          File(
            repoPath('contract/golden/scripts/device-input-permission.json'),
          ).readAsStringSync(),
        )
        as Map;
ScriptPackage package(
  String body, {
  List<String>? permissions,
  int sdk = 10,
}) => ScriptPackage.parse(
  jsonEncode({
    'format': 'elecon-script/1',
    'manifest': {
      ...fixture['baseManifest'] as Map,
      'sdkVersion': sdk,
      'deviceInputs': ?permissions,
    },
    'source':
        "export const capabilities={'attendance.checkin':async(ctx)=>{$body}};",
  }),
);
Future<Object?> run(
  ScriptPackage package, {
  ScriptDeviceInputCall? input,
  bool Function()? active,
  Future<Map<String, Object?>> Function(String, Map<String, dynamic>)? fetch,
}) => const TrustedScriptRuntime().run(
  package: package,
  capability: 'attendance.checkin',
  credentials: ScriptCredentials(
    store: CredentialStore(store: InMemorySecureStore(releaseMode: false)),
    schoolId: 'synthetic',
    scriptId: package.manifest.id,
    sdkVersion: package.manifest.sdkVersion,
  ),
  fetch: fetch ?? (_, _) async => throw StateError('unexpected network'),
  deviceInputCall: input,
  isActive: active,
  wallTimeout: const Duration(seconds: 5),
);
const png = <int>[137, 80, 78, 71, 13, 10, 26, 10, 0];
const image = {'bytes': png, 'mimeType': 'image/png', 'width': 1, 'height': 1};
String caught(String expression, String code) =>
    "try {$expression;return {status:'unknown'};}catch(e){return {status:e.code==='$code'?'confirmed':'rejected'};}";
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final row in fixture['cases'] as List) {
    test('SDK10 admission: ${row['name']}', () {
      final text = jsonEncode({
        'format': 'elecon-script/1',
        'manifest': {
          ...fixture['baseManifest'] as Map,
          ...row['manifest'] as Map,
        },
        'source': 'export const capabilities={};',
      });
      if (row['valid'] == true) {
        expect(() => ScriptPackage.parse(text), returnsNormally);
      } else {
        expect(() => ScriptPackage.parse(text), throwsFormatException);
      }
    });
  }
  test(
    'photo bytes cross QuickJS as Uint8Array and can form a binary upload',
    () async {
      final p = package(
        "const photo=await ctx.ui.capturePhoto();if(!(photo.bytes instanceof Uint8Array))throw Error();await ctx.fetch('https://synthetic.example/upload',{method:'POST',headers:{'Content-Type':'image/png'},body:photo.bytes});return {status:'confirmed'};",
        permissions: ['camera'],
      );
      var uploads = 0;
      expect(
        await run(
          p,
          input: (kind, valid) async {
            expect(kind, 'camera');
            expect(valid(), isTrue);
            return image;
          },
          fetch: (url, init) async {
            uploads++;
            expect(init['body'], png);
            return {'status': 200, 'body': 'ok'};
          },
        ),
        {'status': 'confirmed'},
      );
      expect(uploads, 1);
    },
  );
  test(
    'position observation preserves coordinate system and cancellation is null',
    () async {
      final p = package(
        "const pos=await ctx.ui.getCurrentPosition();if(pos.coordinateSystem!=='wgs84'||pos.accuracyMeters!==5)throw Error();if(await ctx.ui.pickImage()!==null)throw Error();return {status:'confirmed'};",
        permissions: ['location', 'image'],
      );
      expect(
        await run(
          p,
          input: (kind, _) async => kind == 'image'
              ? null
              : {
                  'latitude': 12.3,
                  'longitude': 45.6,
                  'accuracyMeters': 5,
                  'capturedAt': '2026-11-02T00:00:00Z',
                  'coordinateSystem': 'wgs84',
                },
        ),
        {'status': 'confirmed'},
      );
    },
  );
  for (final kind in ['camera', 'image', 'location']) {
    final method = {
      'camera': 'capturePhoto',
      'image': 'pickImage',
      'location': 'getCurrentPosition',
    }[kind];
    test('$kind denied without its declared permission', () async {
      var called = false;
      expect(
        await run(
          package(caught('await ctx.ui.$method()', 'device_input_unavailable')),
          input: (_, _) async {
            called = true;
            return null;
          },
        ),
        {'status': 'confirmed'},
      );
      expect(called, isFalse);
    });
  }
  test('background has no input presenter', () async {
    expect(
      await run(
        package(
          caught('await ctx.ui.pickImage()', 'device_input_unavailable'),
          permissions: ['image'],
        ),
      ),
      {'status': 'confirmed'},
    );
  });
  test('caller arguments and invalid position/image results reject', () async {
    expect(
      await run(
        package(
          caught(
            'await ctx.ui.pickImage({path:"secret"})',
            'device_input_invalid_request',
          ),
          permissions: ['image'],
        ),
        input: (_, _) async => image,
      ),
      {'status': 'confirmed'},
    );
    expect(
      await run(
        package(
          caught('await ctx.ui.pickImage()', 'device_input_invalid_result'),
          permissions: ['image'],
        ),
        input: (_, _) async => {...image, 'path': 'must-not-cross'},
      ),
      {'status': 'confirmed'},
    );
    expect(
      () => validateDeviceInput('location', {
        'latitude': double.nan,
        'longitude': 1,
        'accuracyMeters': 0,
        'capturedAt': '2026-11-02T00:00:00Z',
        'coordinateSystem': 'wgs84',
      }),
      throwsA(isA<ScriptDeviceInputException>()),
    );
    expect(
      () => validateDeviceInput('camera', {
        ...image,
        'bytes': List.filled(maxScriptImageBytes + 1, 0),
      }),
      throwsA(isA<ScriptDeviceInputException>()),
    );
  });
  test(
    'input call limit and serial host ownership prevent concurrent fetch',
    () async {
      expect(
        await run(
          package(
            caught(
              "for(let i=0;i<5;i++)await ctx.ui.pickImage()",
              'device_input_limit',
            ),
            permissions: ['image'],
          ),
          input: (_, _) async => null,
        ),
        {'status': 'confirmed'},
      );
      final pending = Completer<Object?>();
      final started = Completer<void>();
      final p = package(
        "const a=ctx.ui.pickImage();await Promise.resolve();let busy=false;try{await ctx.ui.getCurrentPosition();}catch(e){busy=e.code==='device_input_busy';}await a;return {status:busy?'confirmed':'unknown'};",
        permissions: ['image', 'location'],
      );
      final result = run(
        p,
        input: (_, _) {
          started.complete();
          return pending.future;
        },
      );
      await started.future;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      pending.complete(null);
      expect(await result, {'status': 'confirmed'});
    },
  );
  test('binary version/type/size gates reject before fetch', () async {
    var requests = 0;
    Future<Map<String, Object?>> fetch(String _, Map<String, dynamic> _) async {
      requests++;
      return {'status': 200, 'body': 'ok'};
    }

    for (final sample in [
      (9, 'new Uint8Array([1])'),
      (10, '[1,2]'),
      (10, 'new ArrayBuffer(3)'),
      (10, 'new Uint8Array(1048577)'),
    ]) {
      final p = package(
        "await ctx.fetch('https://synthetic.example/upload',{method:'POST',body:${sample.$2}});return {status:'confirmed'};",
        sdk: sample.$1,
      );
      await expectLater(
        run(p, fetch: fetch),
        throwsA(isA<ScriptRunException>()),
      );
    }
    expect(requests, 0);
  });
  test('pending device input blocks concurrent HTTP host work', () async {
    final pending = Completer<Object?>(), started = Completer<void>();
    var requests = 0;
    final p = package(
      "const image=ctx.ui.pickImage();await Promise.resolve();let blocked=false;try{await ctx.fetch('https://synthetic.example/upload',{method:'POST',body:'synthetic'});}catch(e){blocked=true;}await image;return {status:blocked?'confirmed':'unknown'};",
      permissions: ['image'],
    );
    final result = run(
      p,
      input: (_, _) {
        started.complete();
        return pending.future;
      },
      fetch: (_, _) async {
        requests++;
        return {'status': 200, 'body': 'ok'};
      },
    );
    await started.future;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    pending.complete(null);
    expect(await result, {'status': 'confirmed'});
    expect(requests, 0);
  });

  test('revoked invocation discards late photo result', () async {
    final pending = Completer<Object?>(), started = Completer<void>();
    var active = true;
    final result = run(
      package(
        "await ctx.ui.pickImage();return {status:'confirmed'};",
        permissions: ['image'],
      ),
      active: () => active,
      input: (_, _) {
        started.complete();
        return pending.future;
      },
    );
    await started.future;
    active = false;
    pending.complete(image);
    await expectLater(result, throwsA(isA<ScriptRunException>()));
  });
  for (final outcome in ['null', 'error']) {
    test(
      'background picker $outcome cannot resume a script network request',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var requests = 0;
        server.listen((request) async {
          requests++;
          await request.response.close();
        });
        final session = SessionController();
        addTearDown(() async {
          session.dispose();
          await server.close(force: true);
        });
        final origin = 'http://127.0.0.1:${server.port}';
        final raw =
            jsonDecode(
                  package(
                    "try{await ctx.ui.pickImage();}catch(e){} await ctx.fetch('$origin/submit',{method:'POST',body:'synthetic'});return {status:'confirmed'};",
                    permissions: ['image'],
                  ).encode(),
                )
                as Map;
        raw['manifest']['network'] = {
          'origins': [origin],
          'ipAllow': ['127.0.0.1'],
        };
        final p = ScriptPackage.parse(jsonEncode(raw));
        await session.installTrustedScript(p, approvedDigest: p.digest);
        await session.selectTrustedScriptSchool(p.manifest.id);
        session.scriptDeviceInputPresenter = (_, _, valid, lease) =>
            lease.run(() async {
              session.scriptAppForeground = false;
              expect(valid(), isTrue); // Only the native input remains allowed.
              if (outcome == 'error') {
                throw const ScriptDeviceInputException('device_input_timeout');
              }
              return null;
            });
        final result = await session.runTrustedScript(
          p.manifest.id,
          'attendance.checkin',
        );
        expect(result.ok, isFalse);
        expect(requests, 0);
        session.scriptAppForeground = true;
      },
    );
  }

  test('system picker lease cannot survive revoke', () async {
    final lease = ScriptSystemInputLease();
    final pending = Completer<int>();
    final future = lease.run(() => pending.future);
    expect(lease.active, isTrue);
    lease.revoke();
    pending.complete(1);
    await expectLater(future, throwsA(isA<ScriptDeviceInputException>()));
    expect(lease.active, isFalse);
  });
  test('pixel re-encoding removes appended source metadata', () async {
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    final normalized = await normalizeScriptImage(
      Uint8List.fromList([...bytes, ...utf8.encode('PRIVATE_EXIF_LOCATION')]),
    );
    expect(normalized['mimeType'], 'image/png');
    expect(normalized['width'], 1);
    expect(normalized['height'], 1);
    expect(
      utf8.decode(
        (normalized['bytes'] as List).cast<int>(),
        allowMalformed: true,
      ),
      isNot(contains('PRIVATE_EXIF_LOCATION')),
    );
  });
}
