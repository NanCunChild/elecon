import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../utils/test_utils.dart' show repoPath;
import '../support/climate_fixture.dart';
import 'package:elecon/core/credential/secure_store.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/scripts/runtime.dart';
import 'package:elecon/core/scripts/scanner.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/scanner_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<Object?> run(
    ScriptPackage p, {
    ScriptScanCall? scan,
    bool Function()? active,
    Duration timeout = const Duration(seconds: 5),
    void Function(String, String)? log,
  }) => const TrustedScriptRuntime().run(
    package: p,
    capability: 'notice.list',
    credentials: ScriptCredentials(
      store: CredentialStore(store: InMemorySecureStore(releaseMode: false)),
      schoolId: 'synthetic',
      scriptId: p.manifest.id,
      sdkVersion: p.manifest.sdkVersion,
    ),
    fetch: (_, _) async => throw StateError('unexpected network'),
    scanCall: scan,
    isActive: active,
    wallTimeout: timeout,
    onLog: log,
  );
  final fixture =
      jsonDecode(
            File(
              repoPath('contract/golden/scripts/scanner-permission.json'),
            ).readAsStringSync(),
          )
          as Map;
  for (final row in fixture['cases'] as List) {
    test('SDK8 shared admission: ${row['name']}', () {
      final encoded = jsonEncode({
        'format': 'elecon-script/1',
        'manifest': {
          ...fixture['baseManifest'] as Map,
          ...row['manifest'] as Map,
        },
        'source': 'export const capabilities={};',
      });
      if (row['valid'] == true) {
        expect(
          ScriptPackage.parse(encoded).manifest.scanner,
          row['manifest']['scanner'] == true,
        );
      } else {
        expect(() => ScriptPackage.parse(encoded), throwsFormatException);
      }
    });
  }
  test('ordinary command retains foreground scanner permission', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final raw = jsonDecode(syntheticClimatePackage().encode()) as Map;
    raw['manifest']['sdkVersion'] = 8;
    raw['manifest']['scanner'] = true;
    raw['source'] =
        "export const capabilities={'climate.command':async()=>{await globalThis.__script_scan(0);return {status:'accepted'};}};";
    final p = ScriptPackage.parse(jsonEncode(raw));
    var calls = 0;
    final result = await const TrustedScriptRuntime().run(
      package: p,
      capability: 'climate.command',
      credentials: ScriptCredentials(
        store: CredentialStore(store: InMemorySecureStore(releaseMode: false)),
        schoolId: p.manifest.schoolId,
        scriptId: p.manifest.id,
        sdkVersion: 8,
      ),
      fetch: (_, _) async => throw StateError('unexpected network'),
      scanCall: (_) async {
        calls++;
        return null;
      },
    );
    expect(result, {'status': 'accepted'});
    expect(calls, 1);
  });
  test('SDK8 scanner permission rejects older SDKs and malformed values', () {
    for (var sdk = 1; sdk <= 7; sdk++) {
      expect(() => scannerPackage('', sdk: sdk), throwsFormatException);
      expect(
        scannerPackage('', sdk: sdk, scanner: null).manifest.scanner,
        isFalse,
      );
    }
    final p = scannerPackage('');
    final raw = jsonDecode(p.encode()) as Map;
    for (final invalid in ['true', 1, null]) {
      raw['manifest']['scanner'] = invalid;
      expect(() => ScriptPackage.parse(jsonEncode(raw)), throwsFormatException);
    }
    expect(scannerPackage('', scanner: false).manifest.scanner, isFalse);
    expect(p.digest, isNot(scannerPackage('', scanner: false).digest));
  });
  test('QR result validates exact shape and UTF-8 bytes', () {
    expect(validateScanResult(null), isNull);
    for (final invalid in [
      {'text': '', 'format': 'qrCode'},
      {'text': 'x', 'format': 'code128'},
      {'text': 'x', 'format': 'qrCode', 'image': 'x'},
      {'text': '界' * 1366, 'format': 'qrCode'},
      {'text': 42, 'format': 'qrCode'},
    ]) {
      expect(
        () => validateScanResult(invalid),
        throwsA(isA<ScriptScannerException>()),
      );
    }
    expect(
      validateScanResult({'text': '界' * 1365, 'format': 'qrCode'}),
      isNotNull,
    );
  });
  test(
    'real QuickJS returns text/null and masks scanned text before logging',
    () async {
      final logs = <String>[];
      final p = scannerPackage(
        'const r=await ctx.ui.scanQRCode();ctx.log("info",r.text);return {items:[],sourceSystem:r.format};',
      );
      expect(
        await run(
          p,
          scan: (_) async => {
            'text': 'SYNTHETIC_QR_SECRET',
            'format': 'qrCode',
          },
          log: (_, m) => logs.add(m),
        ),
        {'items': [], 'sourceSystem': 'qrCode'},
      );
      expect(logs.join(), isNot(contains('SYNTHETIC_QR_SECRET')));
      expect(
        await run(
          scannerPackage(
            'const r=await ctx.ui.scanQRCode();return {items:[],sourceSystem:r===null?"cancelled":"bad"};',
          ),
          scan: (_) async => null,
        ),
        {'items': [], 'sourceSystem': 'cancelled'},
      );
    },
  );
  test(
    'raw host function cannot bypass manifest permission or old SDK',
    () async {
      for (final p in [
        scannerPackage(
          'return {items:[],sourceSystem:typeof ctx.ui.scanQRCode};',
          scanner: false,
        ),
        scannerPackage(
          'return {items:[],sourceSystem:typeof ctx.ui.scanQRCode};',
          sdk: 7,
          scanner: null,
        ),
      ]) {
        var calls = 0;
        expect(
          await run(
            p,
            scan: (_) async {
              calls++;
              return null;
            },
          ),
          {'items': [], 'sourceSystem': 'undefined'},
        );
        expect(calls, 0);
        final raw = jsonDecode(p.encode()) as Map;
        raw['source'] =
            'export const capabilities={"notice.list":async()=>{const result=JSON.parse(await globalThis.__script_scan(0));return {items:[],sourceSystem:result.ok===false && result.error.code==="scanner_unavailable"?"denied":"bad"};}};';
        expect(
          await run(
            ScriptPackage.parse(jsonEncode(raw)),
            scan: (_) async {
              calls++;
              return null;
            },
          ),
          {'items': [], 'sourceSystem': 'denied'},
        );
        expect(calls, 0);
      }
    },
  );
  test(
    'scanner limits calls, rejects arguments and serializes concurrent scans',
    () async {
      var calls = 0;
      final p = scannerPackage(
        'const first=ctx.ui.scanQRCode(); let code="";try{await ctx.ui.scanQRCode();}catch(e){code=e.code;} await first; for(let i=0;i<2;i++)await ctx.ui.scanQRCode();try{await ctx.ui.scanQRCode();}catch(e){code+=","+e.code;}try{await ctx.ui.scanQRCode({url:"x"});}catch(e){code+=","+e.code;}return {items:[],sourceSystem:code};',
      );
      expect(
        await run(
          p,
          scan: (_) async {
            calls++;
            await Future<void>.delayed(const Duration(milliseconds: 100));
            return null;
          },
        ),
        {
          'items': [],
          'sourceSystem': 'scanner_busy,scanner_limit,scanner_invalid_request',
        },
      );
      expect(calls, 3);
    },
  );
  test(
    'late scan result is rejected and runtime timeout revokes camera lease',
    () async {
      final started = Completer<void>();
      final answer = Completer<Object?>();
      var active = true;
      final p = scannerPackage(
        'await ctx.ui.scanQRCode();await ctx.credentials.set("late","bad");return {items:[]};',
      );
      final pending = run(
        p,
        active: () => active,
        scan: (_) {
          started.complete();
          return answer.future;
        },
      );
      await started.future;
      active = false;
      answer.complete({'text': 'SYNTHETIC_LATE', 'format': 'qrCode'});
      await expectLater(pending, throwsA(isA<ScriptRunException>()));
      bool Function()? lease;
      await expectLater(
        run(
          p,
          timeout: const Duration(milliseconds: 150),
          scan: (valid) {
            lease = valid;
            return Completer<Object?>().future;
          },
        ),
        throwsA(
          isA<ScriptRunException>().having(
            (e) => e.code,
            'code',
            'wall_timeout',
          ),
        ),
      );
      expect(lease, isNotNull);
      expect(lease!(), isFalse);
    },
  );
  test('background session cannot invoke its scanner presenter', () async {
    final session = SessionController();
    addTearDown(session.dispose);
    final p = scannerPackage(
      'try{await ctx.ui.scanQRCode();}catch(e){return {items:[],sourceSystem:e.code};}return {items:[]};',
    );
    await session.bootstrap();
    await session.installTrustedScript(p, approvedDigest: p.digest);
    await session.selectTrustedScriptSchool(p.manifest.id);
    var calls = 0;
    session.scriptScannerPresenter = (_, _) async {
      calls++;
      return null;
    };
    final result = await session.runCapability(
      'notice.list',
      interactive: false,
    );
    expect(result.ok, isTrue, reason: result.reason);
    expect((result.data as Map)['sourceSystem'], 'scanner_unavailable');
    expect(calls, 0);
  });
}
