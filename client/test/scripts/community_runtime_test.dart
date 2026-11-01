import 'dart:convert';
import 'dart:io';

import 'package:elecon/core/credential/secure_store.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/scripts/runtime.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ScriptPackage enhancement;
  late CredentialStore store;
  setUp(() {
    enhancement = ScriptPackage.parse(
      File(
        'assets/school-scripts/enhancement-xidian-undergraduate-chaoxing.elecon.json',
      ).readAsStringSync(),
    );
    store = CredentialStore(store: InMemorySecureStore(releaseMode: false));
  });
  ScriptCredentials credentials(ScriptPackage p) => ScriptCredentials(
    store: store,
    schoolId: p.manifest.schoolId,
    scriptId: p.manifest.id,
    sdkVersion: p.manifest.sdkVersion,
  );
  test(
    'built SDK9 enhancement executes account, QR cancel and binary socket in real QuickJS',
    () async {
      final c = credentials(enhancement);
      c.set(
        'chaoxing',
        jsonEncode({
          'version': 1,
          'serviceId': 'chaoxing',
          'accountId': '123456',
          'accountLabel': 'Synthetic',
          'cookies': [],
        }),
        namespace: 'xidian.services',
      );
      Future<Map<String, Object?>> fetch(
        String url,
        Map<String, dynamic> init,
      ) async => {
        'status': 200,
        'url': url,
        'headers': <String, List<String>>{},
        'body': jsonEncode({
          'msg': {
            'puid': 123456,
            'uid': 456789,
            'fid': 789012,
            'name': 'Synthetic',
            'hxToken': 'SYNTHETIC_TOKEN',
          },
        }),
      };
      final status = await const TrustedScriptRuntime().run(
        package: enhancement,
        capability: 'messages.session',
        credentials: c,
        fetch: fetch,
      );
      expect((status as Map)['status'], 'authenticated');
      final cancelled = await const TrustedScriptRuntime().run(
        package: enhancement,
        capability: 'attendance.checkin',
        credentials: c,
        fetch: fetch,
        scanCall: (_) async => null,
      );
      expect((cancelled as Map)['status'], 'cancelled');
      var activityReads = 0;
      final ended = await const TrustedScriptRuntime().run(
        package: enhancement,
        capability: 'attendance.checkin',
        credentials: c,
        scanCall: (_) async => {
          'text':
              'https://mobilelearn.chaoxing.com/widget/sign/e?id=123456789&enc=0123456789abcdef0123456789abcdef',
          'format': 'qrCode',
        },
        fetch: (url, init) async {
          expect(init['method'], 'GET');
          if (url.contains('getUserImToken')) return fetch(url, init);
          activityReads++;
          return {
            'status': 200,
            'url': url,
            'headers': <String, List<String>>{},
            'body': jsonEncode({
              'data': {
                'status': 0,
                if (url.contains('getPPTActiveInfo')) 'isdelete': 0,
              },
            }),
          };
        },
      );
      expect((ended as Map)['status'], 'ended');
      expect(ended['activityId'], '123456789');
      expect(activityReads, 2);
      var receive = 0;
      final calls = <String>[];
      final result = await const TrustedScriptRuntime().run(
        package: enhancement,
        capability: 'messages.list',
        credentials: c,
        fetch: fetch,
        websocketCall: (method, args) async {
          calls.add(method);
          if (method == 'send') {
            expect((args['bytes'] as List).length, greaterThan(50));
          }
          // Independent wire fixture: MSync(command=3, payload=Provision(status=0)).
          if (method == 'receive') {
            return receive++ == 0 ? [64, 3, 74, 4, 66, 2, 8, 0] : null;
          }
          return null;
        },
      );
      expect((result as Map)['coverage'], 'window');
      expect(result['items'], isEmpty);
      expect(calls, ['open', 'send', 'receive', 'receive', 'close']);
      expect(
        c.get('chaoxing', namespace: 'xidian.services')!['value'],
        isNot(contains('SYNTHETIC_TOKEN')),
      );
    },
  );
  test(
    'built base package performs Ruisi form login through real DOM/input/credential bridges',
    () async {
      final p = ScriptPackage.parse(
        File(
          'assets/school-scripts/school-xidian-undergraduate.elecon.json',
        ).readAsStringSync(),
      );
      final c = credentials(p);
      var posts = 0;
      final result = await const TrustedScriptRuntime().run(
        package: p,
        capability: 'forum.session',
        params: {'operation': 'login'},
        credentials: c,
        htmlStdlib: File('assets/stdlib/html.bundle.js').readAsStringSync(),
        inputCall: (request) async => {
          'username': 'SYNTHETIC_USER',
          'password': 'SYNTHETIC_PASSWORD',
        },
        fetch: (url, init) async {
          String body;
          if (init['method'] == 'POST') {
            posts++;
            expect(init['body'], isNot(contains('SYNTHETIC_PASSWORD')));
            body = '欢迎您回来';
          } else if (url.contains('mod=space')) {
            body =
                '<div id="um"><strong class="vwmy"><a href="home.php?mod=space&uid=112233">Synthetic</a></strong><a href="member.php?action=logout">退出</a></div>';
          } else {
            body =
                '<form id="loginform_SYNTHETIC" action="member.php?loginhash=SYNTHETIC"><input name="formhash" value="FORMHASH"></form>';
          }
          return {
            'status': 200,
            'url': url,
            'headers': {
              'set-cookie': ['SYNTHETIC_SESSION=VALUE; Path=/; Secure'],
            },
            'body': body,
          };
        },
      );
      expect((result as Map)['accountId'], '112233');
      expect(posts, 1);
      expect(
        c.get('xidian.ruisi', namespace: 'xidian.services')!['value'],
        isNot(contains('SYNTHETIC_PASSWORD')),
      );
    },
  );

  test(
    'sensitive capabilities cannot enter home or execute in background',
    () async {
      final raw = jsonDecode(enhancement.encode()) as Map<String, dynamic>;
      for (final cap in [
        'messages.session',
        'messages.list',
        'attendance.checkin',
      ]) {
        final m = Map<String, dynamic>.from(raw['manifest'] as Map)
          ..['home'] = [
            {'capability': cap, 'ttlSeconds': 30, 'preload': false},
          ];
        expect(() => ScriptManifest.fromJson(m), throwsFormatException);
      }
      final session = SessionController();
      addTearDown(session.dispose);
      await session.installTrustedScript(
        enhancement,
        approvedDigest: enhancement.digest,
      );
      await session.selectTrustedScriptSchool(enhancement.manifest.id);
      final result = await session.runTrustedScript(
        enhancement.manifest.id,
        'messages.list',
        interactive: false,
      );
      expect(result.reason, 'foreground_required');
    },
  );
  test(
    'SDK8 cannot grant sockets and HTTP origins do not grant socket origins',
    () async {
      final raw = jsonDecode(enhancement.encode()) as Map<String, dynamic>;
      final manifest = Map<String, dynamic>.from(raw['manifest'] as Map);
      expect(
        () => ScriptManifest.fromJson({...manifest, 'sdkVersion': 8}),
        throwsFormatException,
      );
      expect(
        () => ScriptManifest.fromJson({
          ...manifest,
          'websocketOrigins': ['ws://example.invalid'],
        }),
        throwsFormatException,
      );
      final p = ScriptPackage.parse(
        jsonEncode({
          ...raw,
          'manifest': {...manifest, 'websocketOrigins': <String>[]},
          'source':
              "export const capabilities={'messages.session':async ctx=>{if(ctx.websocket)throw new Error();return {serviceId:'synthetic',serviceName:'Synthetic',status:'signedOut'}}}",
        }),
      );
      final output = await const TrustedScriptRuntime().run(
        package: p,
        capability: 'messages.session',
        credentials: credentials(p),
        fetch: (_, _) async => throw StateError('no network'),
      );
      expect((output as Map)['status'], 'signedOut');
    },
  );
}
