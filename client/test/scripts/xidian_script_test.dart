// Actual compiled SDK 4/5 packages, synthetic school responses, real QuickJS.
import 'dart:convert';
import 'dart:io';

import 'package:elecon/core/credential/secure_store.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/scripts/runtime.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> response(String url, Object body, {int status = 200}) => {
  'status': status,
  'url': url,
  'headers': <String, List<String>>{},
  'body': body is String ? body : jsonEncode(body),
};
Map<String, Object?> table(String name, List<Object> rows) => {
  'code': '0',
  'datas': {
    name: {
      'rows': rows,
      'totalSize': rows.length,
      'extParams': {'code': 1},
    },
  },
};

// Production authentication: only the official IDS document is rendered.
class WebViewFixture {
  WebViewFixture({this.pg = false, this.businessFailure = false});
  final bool pg, businessFailure;
  final opened = <String>[];
  final logs = <String>[];
  final busyStates = <bool>[];
  int authenticatedProbes = 0;
  int cookieReads = 0;
  String get origin =>
      pg ? 'https://yjspt.xidian.edu.cn' : 'https://ehall.xidian.edu.cn';
  Future<Object?> browser(String method, Map<String, Object?> args) async {
    switch (method) {
      case 'open':
        expect(args['url'], 'https://ids.xidian.edu.cn/authserver/login');
        opened.add(args['url'] as String);
        return null;
      case 'evaluate':
        if ((args['source'] as String).contains(
          'function inspectIdsLocation',
        )) {
          return 'https://ids.xidian.edu.cn/personalInfo/personalMobile/index.html';
        }
        expect(args['source'], contains('function inspectLoginPage'));
        authenticatedProbes++;
        await Future<void>.delayed(const Duration(milliseconds: 250));
        return {
          'ready': true,
          'page':
              'https://ids.xidian.edu.cn/personalInfo/personalMobile/index.html',
        };
      case 'cookies':
        cookieReads++;
        return [
          {
            'name': 'CASTGC',
            'value': 'SYNTHETIC-GLOBAL',
            'path': '/authserver',
            'isSecure': true,
            'isHttpOnly': true,
          },
        ];
      case 'setCookies':
        return null;
      case 'setBusy':
        busyStates.add(args['busy'] as bool);
        return null;
      default:
        throw StateError('unexpected browser operation');
    }
  }

  Future<Map<String, Object?>> fetch(
    String url,
    Map<String, dynamic> init,
  ) async {
    final uri = Uri.parse(url);
    if (uri.host == 'ids.xidian.edu.cn') {
      expect(uri.path, '/authserver/login');
      expect(init['method'], 'GET');
      expect((init['headers'] as Map)['Cookie'], contains('SYNTHETIC-GLOBAL'));
      return {
        ...response(url, '', status: 302),
        'headers': <String, List<String>>{
          'location': [
            pg ? '$origin/' : '$origin/appShow?appId=4770397878132218',
          ],
          'set-cookie': [
            'CASTGC=SYNTHETIC-ROTATED; Path=/authserver; Secure; HttpOnly',
          ],
        },
      };
    }
    expect(uri.origin, origin);
    if (init['method'] == 'POST') {
      return response(
        url,
        businessFailure
            ? '<html>调用接口异常</html>'
            : {
                ...table('dqxnxq', [
                  {'DM': '2026-2027-1'},
                ]),
                'data': {'xnxqdm': '2026-2027-1'},
              },
      );
    }
    return {
      ...response(url, '<html>系统异常 / 调用接口异常 / 正在紧急修复</html>'),
      'headers': <String, List<String>>{
        'set-cookie': [
          'MOD_AUTH_CAS=SYNTHETIC-BUSINESS; Path=/; Secure; HttpOnly',
        ],
      },
    };
  }
}

// Synthetic IDS/SSO exchange shared by real QuickJS regression cases.
class PdaFixture {
  PdaFixture({
    this.pg = false,
    this.fresh = false,
    this.businessFailure = false,
    this.mobileGlobal = false,
    this.mfaCancelled = false,
  });
  final bool pg, fresh, businessFailure, mobileGlobal, mfaCancelled;
  bool primarySubmitted = false;
  String inputKind = '';
  final opened = <String>[];
  final requested = <String>[];
  final logs = <String>[];
  String get origin =>
      pg ? 'https://yjspt.xidian.edu.cn' : 'https://ehall.xidian.edu.cn';
  String get service =>
      pg ? '$origin/' : '$origin/appShow?appId=4770397878132218';
  Map<String, Object?> redirect(
    String url,
    String location, {
    bool global = false,
  }) => {
    ...response(url, '', status: 302),
    'headers': <String, List<String>>{
      'location': [location],
      if (global)
        'set-cookie': [
          'CASTGC=SYNTHETIC-GLOBAL; Path=/authserver; Secure; HttpOnly',
        ],
    },
  };
  Future<Map<String, Object?>> fetch(
    String url,
    Map<String, dynamic> init,
  ) async {
    requested.add(url);
    final uri = Uri.parse(url);
    expect((init['headers'] as Map)['User-Agent'], contains('XDYou/2.0.0'));
    if (uri.path == '/authserver/login') {
      if (uri.queryParameters.containsKey('service')) {
        expect(uri.queryParameters['service'], service);
        expect(
          (init['headers'] as Map)['Cookie'],
          contains('CASTGC=SYNTHETIC-GLOBAL'),
        );
        return redirect(url, service);
      }
      if (init['method'] == 'POST') {
        final fields = Uri.splitQueryString(init['body'] as String);
        expect(fields['password'], 'SYNTHETIC-ENCRYPTED');
        expect(fields['lt'], '');
        expect(fields['execution'], 'SYNTHETIC-EXECUTION');
        primarySubmitted = true;
      }
      if (mfaCancelled) {
        return redirect(
          url,
          '/authserver/reAuthCheck/reAuthLoginView.do?isMultifactor=true',
          global: true,
        );
      }
      if (fresh && !primarySubmitted) {
        return response(
          url,
          '<form id="pwdFromId"><input type="hidden" name="pwdEncryptSalt" value="0123456789abcdef"><input type="hidden" name="lt" value=""><input type="hidden" name="execution" value="SYNTHETIC-EXECUTION"></form>',
        );
      }
      return redirect(
        url,
        mobileGlobal
            ? '/personalInfo/personalMobile/index.html'
            : 'http://ids.xidian.edu.cn/authserver/index.do',
        global: true,
      );
    }
    if (uri.path.endsWith('/bfp/info')) return response(url, 'ok');
    if (uri.path.endsWith('/openSliderCaptcha.htl')) {
      return response(url, {
        'bigImage': base64Encode(List<int>.filled(32, 7)),
        'smallImage': base64Encode(List<int>.filled(32, 8)),
      });
    }
    if (uri.path.endsWith('/verifySliderCaptcha.htl')) {
      return response(url, {'errorCode': 1});
    }
    if (uri.path.endsWith('/reAuthLoginView.do')) {
      return response(url, '{"reAuthUserId":"SYNTHETIC-DELIVERY"}');
    }
    if (uri.origin == origin) {
      if (uri.path.endsWith('.do') && init['method'] == 'POST') {
        if (businessFailure) return response(url, '<html>正在紧急修复</html>');
        return response(url, {
          'code': '0',
          'data': {'xnxqdm': '2026-2027-1'},
          ...table('dqxnxq', [
            {'DM': '2026-2027-1'},
          ]),
        });
      }
      return {
        ...response(url, 'application'),
        'headers': <String, List<String>>{
          'set-cookie': [
            'MOD_AUTH_CAS=SYNTHETIC-BUSINESS; Path=/; Secure; HttpOnly',
          ],
        },
      };
    }
    throw StateError('unexpected synthetic request');
  }

  Future<Object?> browser(String method, Map<String, Object?> args) async {
    if (method == 'open') {
      opened.add(args['url'] as String);
      return null;
    }
    expect(method, 'evaluate');
    final source = args['source'] as String;
    if (source.contains('function preparePdaInput')) {
      return '0123456789ABCDEF0123456789ABCDEF';
    }
    if (source.contains('function encryptPda')) return 'SYNTHETIC-ENCRYPTED';
    if (source.contains('function renderPdaInput')) {
      final values =
          jsonDecode(
                source.substring(
                  source.lastIndexOf('.apply(null,') + 12,
                  source.length - 1,
                ),
              )
              as List;
      inputKind = (values.single as Map)['kind'] as String;
      return true;
    }
    if (source.contains('function pollPdaInput')) {
      if (mfaCancelled) return {'cancelled': true};
      return switch (inputKind) {
        'credentials' => {
          'username': 'SYNTHETIC-ACCOUNT',
          'password': 'SYNTHETIC-PASSWORD',
        },
        'captcha' => {
          'tracks': [
            {'a': 0, 'b': 0, 'c': 0},
            {'a': 120, 'b': 1, 'c': 500},
          ],
        },
        _ => throw StateError('unexpected input'),
      };
    }
    if (source.contains('function clearPdaInput')) return true;
    throw StateError('unexpected browser function');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ScriptPackage school;
  late ScriptPackage login;
  late ScriptPackage undergraduate;
  late ScriptPackage postgraduate;
  late ScriptPackage undergraduateLogin;
  late ScriptPackage postgraduateLogin;
  late ScriptPackage experimentalPda;
  late String htmlStdlib;
  late ScriptCredentials credentials;
  late CredentialStore store;
  const runtime = TrustedScriptRuntime();

  setUpAll(() async {
    // CI installs the Node workspace too. Compile authored modules rather than
    // maintaining a second hand-written implementation in test fixtures.
    final built = await Process.run(Platform.isWindows ? 'npm.cmd' : 'npm', [
      'run',
      'scripts:xidian',
      '-w',
      'tools',
    ], workingDirectory: '..');
    expect(
      built.exitCode,
      0,
      reason:
          'Install Node dependencies with npm ci before this integration suite. ${built.stderr}',
    );
    undergraduate = ScriptPackage.parse(
      await File(
        '../school-scripts/xidian/dist/school-xidian-undergraduate.elecon.json',
      ).readAsString(),
    );
    undergraduateLogin = undergraduate;
    postgraduate = ScriptPackage.parse(
      await File(
        '../school-scripts/xidian/dist/school-xidian-postgraduate.elecon.json',
      ).readAsString(),
    );
    postgraduateLogin = postgraduate;
    htmlStdlib = await File('assets/stdlib/html.bundle.js').readAsString();
    // Keep the existing password-protocol regressions, but compile a test-only
    // entry. Production school assets must never import this experiment.
    final protocol = await Process.run('node', [
      '--input-type=module',
      '-e',
      '''import {build} from 'esbuild';
const result=await build({stdin:{contents:'import {pdaLogin} from "./school-scripts/xidian/src/pda_login.js";export const capabilities={"generic.section":(ctx,p)=>pdaLogin(ctx,{...p,system:p.system??"ehall"},"undergraduate")};',resolveDir:process.cwd()},bundle:true,write:false,format:'esm',platform:'neutral',target:'es2020',external:['elecon:html']});
process.stdout.write(result.outputFiles[0].text);''',
    ], workingDirectory: '..');
    expect(protocol.exitCode, 0, reason: '${protocol.stderr}');
    final protocolJson =
        jsonDecode(undergraduate.encode()) as Map<String, dynamic>;
    protocolJson['source'] = protocol.stdout as String;
    experimentalPda = ScriptPackage.parse(jsonEncode(protocolJson));
  });
  setUp(() {
    school = undergraduate;
    login = undergraduateLogin;
    store = CredentialStore(store: InMemorySecureStore(releaseMode: false));
    credentials = ScriptCredentials(
      store: store,
      schoolId: school.manifest.schoolId,
      scriptId: school.manifest.id,
      sdkVersion: school.manifest.sdkVersion,
    );
  });

  void seed(
    String service, {
    Map<String, Object?> data = const {},
    List<Object> cookies = const [],
  }) {
    credentials.set(
      service,
      jsonEncode({
        'version': 1,
        'service': service,
        'data': data,
        'cookies': cookies,
      }),
      namespace: 'xidian.auth',
    );
  }

  Future<Object?> run(
    String capability, {
    Map<String, dynamic> params = const {},
    required Future<Map<String, Object?>> Function(String, Map<String, dynamic>)
    fetch,
  }) => runtime.run(
    package: school,
    capability: capability,
    params: params,
    credentials: credentials,
    fetch: fetch,
    htmlStdlib: htmlStdlib,
  );

  test(
    'source packages bind SDK 12 and combine browser login with authenticated data',
    () {
      expect(school.manifest.sdkVersion, 12);
      expect(school.manifest.version, '0.22.0');
      expect(school.manifest.browser, isTrue);
      expect(school.manifest.capabilities, hasLength(22));
      expect(school.manifest.capability('notice.detail'), isNotNull);
      expect(login.manifest.browser, isTrue);
      expect(login.manifest.schoolId, school.manifest.schoolId);
      expect(school.manifest.schoolId, 'xidian_undergraduate');
      expect(postgraduate.manifest.schoolId, 'xidian_postgraduate');
      expect(
        postgraduateLogin.manifest.schoolId,
        postgraduate.manifest.schoolId,
      );
    },
  );

  test(
    'built-in classroom directory works without credentials or requests',
    () async {
      final result =
          await run(
                'classroom.buildings',
                params: {'campus': 'S'},
                fetch: (_, _) async =>
                    throw StateError('directory must be offline'),
              )
              as Map;
      final items = result['items'] as List;
      expect(items, isNotEmpty);
      expect(items.every((item) => item['campus'] == 'S'), isTrue);
      expect(items.any((item) => item['buildingId'] == 'A'), isTrue);
    },
  );

  test(
    'actual QR source returns PNG through QuickJS and output validation',
    () async {
      seed(
        'card',
        data: {
          'openid': 'SYNTHETIC-OPENID',
          'openidFetchedAt': DateTime.now().millisecondsSinceEpoch,
        },
      );
      const png =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jD0sAAAAASUVORK5CYII=';
      var calls = 0;
      final result =
          await run(
                'card.qr',
                fetch: (url, init) async {
                  calls++;
                  if (Uri.parse(url).path == '/home/openHomePage') {
                    return response(
                      url,
                      '<a href="/virtualcard/openVirtualcard?id=SYNTHETIC">card</a>',
                    );
                  }
                  expect(Uri.parse(url).path, '/virtualcard/openVirtualcard');
                  return response(
                    url,
                    '<img id="qrcode" src="data:image/png;base64,$png">',
                  );
                },
              )
              as Map;
      expect(result['imageBase64'], png);
      expect(calls, 2);
      expect(
        DateTime.parse(
          result['expiresAt'] as String,
        ).difference(DateTime.parse(result['issuedAt'] as String)).inSeconds,
        30,
      );
    },
  );

  test(
    'actual card source returns account balance without inventing a missing card number',
    () async {
      seed(
        'card',
        data: {
          'openid': 'SYNTHETIC-OPENID',
          'openidFetchedAt': DateTime.now().millisecondsSinceEpoch,
        },
      );
      var requests = 0;
      Future<Map<String, Object?>> account(
        String url,
        Map<String, dynamic> init,
      ) async {
        requests++;
        expect(Uri.parse(url).path, '/myaccount/openMyAccount');
        return response(url, '<p>账户余额：￥12.34</p>');
      }

      final withoutNumber = await run('card.balance', fetch: account) as Map;
      expect(withoutNumber.containsKey('cardNumber'), isFalse);
      expect(withoutNumber['balance'], {
        'amountMinor': 1234,
        'currency': 'CNY',
      });
      final result = await run(
        'card.balance',
        params: {'cardNumber': 'CARD-SYNTHETIC'},
        fetch: account,
      );
      expect((result as Map)['balance'], {
        'amountMinor': 1234,
        'currency': 'CNY',
      });
      expect(requests, 2);
    },
  );

  test(
    'legacy HTTP E-Hall sessions keep their verified business origin',
    () async {
      seed(
        'ehall',
        data: {'origin': 'http://ehall.xidian.edu.cn'},
        cookies: [
          {
            'name': 'SID',
            'value': 'SYNTHETIC-LEGACY',
            'domain': 'ehall.xidian.edu.cn',
            'hostOnly': true,
            'path': '/',
            'isSecure': false,
          },
        ],
      );
      final output = await run(
        'term.list',
        fetch: (url, init) async {
          expect(Uri.parse(url).origin, 'http://ehall.xidian.edu.cn');
          expect(
            (init['headers'] as Map)['Cookie'],
            contains('SYNTHETIC-LEGACY'),
          );
          return response(
            url,
            Uri.parse(url).path == '/appShow'
                ? '<html>App</html>'
                : table('dqxnxq', [
                    {'DM': '2026-2027-1'},
                  ]),
          );
        },
      );
      expect((output as Map)['currentTerm'], '2026-2027-1');
    },
  );

  test(
    'public notices fetch directly and parse through the actual built-in HTML module',
    () async {
      final out =
          await run(
                'notice.list',
                fetch: (url, init) async {
                  expect(url, 'https://jwc.xidian.edu.cn/index.htm');
                  expect(init['headers'], isNull);
                  return response(
                    url,
                    '<div class="tit">通知公告</div><ul><li><a href="info/1001/42.htm">合成教学通知</a><div class="time"><span>2026.10</span><p>30</p></div></li></ul>',
                  );
                },
              )
              as Map;
      expect(
        (out['items'] as List).single,
        containsPair('publishedAt', '2026-10-30T00:00:00Z'),
      );
      expect(
        (out['items'] as List).single,
        containsPair('url', 'https://jwc.xidian.edu.cn/info/1001/42.htm'),
      );
      expect(store.list(), isEmpty);
    },
  );

  test(
    'notice titles omit nested dates and detail parses through real QuickJS',
    () async {
      final list =
          await run(
                'notice.list',
                fetch: (url, init) async => response(
                  url,
                  '<div class="tit">通知公告</div><ul><li><a title="合成公告" href="info/1012/42.htm"><div class="time"><p>13</p><span>2026.10</span></div><p>合成公告…</p></a></li></ul>',
                ),
              )
              as Map;
      final item = (list['items'] as List).single as Map;
      expect(item['title'], '合成公告');
      expect(item['publishedAt'], '2026-10-13T00:00:00Z');
      final detail =
          await run(
                'notice.detail',
                params: {'id': item['id'], 'url': item['url']},
                fetch: (url, init) async {
                  expect(url, item['url']);
                  expect(init['headers'], isNull);
                  return response(
                    url,
                    '<div class="nry_con"><div class="con"><p class="tit">合成公告</p><div id="vsb_content"><div class="v_news_content"><style>hidden</style><p>第一段合成正文</p><p>第二段合成正文</p><script>hidden()</script></div></div></div></div>',
                  );
                },
              )
              as Map;
      expect(detail['id'], '42');
      expect(detail['content'], '第一段合成正文\n\n第二段合成正文');
      expect(store.list(), isEmpty);
    },
  );

  test(
    'UG bitmap schedule is filtered and carries the saved service-specific student id',
    () async {
      seed(
        'ids',
        data: {'role': 'undergraduate', 'studentId': 'UNRELATED_OLD_ID'},
      );
      seed(
        'ehall',
        data: {'studentId': 'SYNTHETIC_UG'},
        cookies: [
          {
            'name': 'SID',
            'value': 'SYNTHETIC_SESSION',
            'domain': 'ehall.xidian.edu.cn',
            'hostOnly': true,
            'path': '/',
            'isSecure': true,
          },
        ],
      );
      final out =
          await run(
                'schedule.week',
                params: {'term': '2026-2027-1', 'week': 3},
                fetch: (url, init) async {
                  expect(
                    (init['headers'] as Map)['Cookie'],
                    'SID=SYNTHETIC_SESSION',
                  );
                  if (url.contains('/appShow?')) {
                    return response(url, '<html>app</html>');
                  }
                  if (url.endsWith('/cxjcs.do')) {
                    return response(
                      url,
                      table('cxjcs', [
                        {'XQKSRQ': '2026-09-07'},
                      ]),
                    );
                  }
                  if (url.endsWith('/xsdkkc.do')) {
                    return response(url, table('xsdkkc', []));
                  }
                  expect(url.endsWith('/xskcb.do'), isTrue);
                  expect(
                    Uri.splitQueryString(init['body'] as String)['XH'],
                    'SYNTHETIC_UG',
                  );
                  return response(
                    url,
                    table('xskcb', [
                      {
                        'KCM': 'Synthetic course',
                        'KCH': 'C1',
                        'KXH': '1',
                        'KSJC': 1,
                        'JSJC': 2,
                        'SKXQ': 1,
                        'SKZC': '1010',
                        'SKJS': 'Example teacher',
                        'JASMC': 'Example room',
                      },
                    ]),
                  );
                },
              )
              as Map;
      final monday = (out['days'] as List).first as Map;
      expect(
        (monday['slots'] as List).single,
        containsPair('date', '2026-09-21'),
      );
      expect((monday['slots'] as List).single, containsPair('weeks', [1, 3]));
    },
  );

  test(
    'PG school routes grade queries to yjspt regardless of a stale saved role',
    () async {
      school = postgraduate;
      credentials = ScriptCredentials(
        store: store,
        schoolId: school.manifest.schoolId,
        scriptId: school.manifest.id,
        sdkVersion: school.manifest.sdkVersion,
      );
      seed('ids', data: {'role': 'undergraduate'});
      seed('yjspt', data: {'studentId': 'SYNTHETIC_PG'});
      final out =
          await run(
                'grades.list',
                params: {'term': '2026-2027-1'},
                fetch: (url, init) async {
                  expect(Uri.parse(url).host, 'yjspt.xidian.edu.cn');
                  if (url.contains('/index.do')) {
                    return response(url, '<html>app</html>');
                  }
                  expect(url, contains('/wdcjapp/modules/wdcj/xscjcx.do'));
                  return response(
                    url,
                    table('xscjcx', [
                      {
                        'KCMC': 'Synthetic PG course',
                        'KCDM': 'PG1',
                        'DYBFZCJ': '0',
                        'CJFZDM': '0',
                        'XF': '2',
                        'SFJG': '0',
                        'XNXQDM_DISPLAY': '2026-2027-1',
                        'KCLBMC': '必修',
                        'KSXZDM_DISPLAY': '正常考试',
                      },
                    ]),
                  );
                },
              )
              as Map;
      final item = (out['items'] as List).single as Map;
      expect((item['score'] as Map)['value'], 0);
      expect(out['gradePointScale'], 'unknown');
      expect(item.containsKey('gradePoint'), isFalse);
    },
  );

  test(
    'China exam wall time is normalized to UTC in the real package',
    () async {
      seed('ehall');
      final out =
          await run(
                'exam.list',
                params: {'term': '2026-2027-1'},
                fetch: (url, init) async {
                  if (url.contains('/appShow?')) return response(url, 'app');
                  if (url.contains('/cxyxkwapkwdkc.do')) {
                    return response(url, table('cxyxkwapkwdkc', []));
                  }
                  return response(
                    url,
                    table('wdksap', [
                      {
                        'KCM': 'Synthetic exam',
                        'KSSJMS': '2026-10-30 09:00-11:00',
                        'JASMC': 'Synthetic room',
                        'ZWH': '1',
                      },
                    ]),
                  );
                },
              )
              as Map;
      expect(
        ((out['items'] as List).single as Map)['examAt'],
        '2026-10-30T01:00:00.000Z',
      );
    },
  );

  test(
    'card uses the witnessed HTML layout and date-window JSON; configured number is reused',
    () async {
      seed(
        'card',
        data: {
          'openid': 'SYNTHETIC_OPENID',
          'openidFetchedAt': DateTime.now().millisecondsSinceEpoch,
        },
      );
      final balance =
          await run(
                'card.balance',
                params: {'cardNumber': 'CARD-SYNTHETIC'},
                fetch: (url, init) async => response(
                  url,
                  '<ul><li><div>校园卡</div><div><p>金额</p><p>28.09</p></div></li></ul>',
                ),
              )
              as Map;
      expect((balance['balance'] as Map)['amountMinor'], 2809);
      final transactions =
          await run(
                'card.transactions',
                params: {'from': '2026-10-01', 'to': '2026-10-30'},
                fetch: (url, init) async {
                  final body = jsonDecode(init['body'] as String) as Map;
                  expect(body['beginDate'], '2026-10-01');
                  expect(body['endDate'], '2026-10-30');
                  expect(body['openid'], 'SYNTHETIC_OPENID');
                  return response(url, {
                    'resultData': [
                      {
                        'mername': 'Synthetic merchant',
                        'txdate': '2026-10-30 09:00:00',
                        'txamt': '12.30',
                      },
                    ],
                  });
                },
              )
              as Map;
      expect(transactions['cardNumber'], 'CARD-SYNTHETIC');
      expect(
        (transactions['items'] as List).single,
        containsPair('direction', 'credit'),
      );
    },
  );

  test(
    'actual exam source accepts the PDA top-level success independently of table status',
    () async {
      seed('ehall');
      final out = await run(
        'exam.list',
        params: {'term': '2026-2027-1'},
        fetch: (url, init) async {
          if (init['method'] != 'POST') {
            return response(url, '<html>app</html>');
          }
          final pending = Uri.parse(url).path.endsWith('/cxyxkwapkwdkc.do');
          final name = pending ? 'cxyxkwapkwdkc' : 'wdksap';
          return response(url, {
            'code': '0',
            'datas': {
              name: {
                'rows': pending
                    ? <Object>[]
                    : [
                        {
                          'KCM': 'Synthetic exam',
                          'KSSJMS': '2026-11-02 8:30-10:30',
                        },
                      ],
                'totalSize': pending ? 0 : 1,
                'extParams': {'code': 0},
              },
            },
          });
        },
      );
      expect(
        ((out as Map)['items'] as List).single,
        containsPair('courseName', 'Synthetic exam'),
      );
    },
  );

  test(
    'actual academic calendar computes the current school week in real QuickJS',
    () async {
      seed('ehall');
      final chinaNow = DateTime.now().toUtc().add(const Duration(hours: 8));
      final start = chinaNow
          .subtract(const Duration(days: 15))
          .toIso8601String()
          .substring(0, 10);
      final out = await run(
        'calendar.academic',
        params: {'term': '2026-2027-1'},
        fetch: (url, init) async {
          if (init['method'] != 'POST') {
            return response(url, '<html>app</html>');
          }
          return response(
            url,
            table('cxjcs', [
              {'XQKSRQ': start},
            ]),
          );
        },
      );
      expect((out as Map)['currentWeek'], 3);
      expect(out['startDate'], start);
    },
  );

  test(
    'library opens the official CAS initializer and cancellation cannot save a session',
    () async {
      final opened = <String>[];
      await expectLater(
        runtime.run(
          package: school,
          capability: 'library.loans',
          credentials: credentials,
          htmlStdlib: htmlStdlib,
          fetch: (_, _) async =>
              throw StateError('cancelled library login must not read loans'),
          browserCall: (method, args) async {
            expect(method, 'open');
            opened.add(args['url'] as String);
            throw const ScriptRunException('invocation_cancelled');
          },
        ),
        throwsA(isA<ScriptRunException>()),
      );
      expect(opened, [
        'https://tyrzfw.chaoxing.com/auth/xidian/cas/init?isLogout=0&refer='
            'https%3A%2F%2Fmfindxidian.libsp.cn%2Ffind%2Fsso%2Flogin%2Fxidian%2F1',
      ]);
      expect(store.list(), isEmpty);
    },
  );

  test(
    'new OPAC token is sent in both the header and cookies before reading loans',
    () async {
      seed(
        'library',
        data: {'token': 'SYNTHETIC_JWT', 'groupCode': 'SYNTHETIC_GROUP'},
      );
      final out =
          await run(
                'library.loans',
                fetch: (url, init) async {
                  expect(
                    (init['headers'] as Map)['jwtOpacAuth'],
                    'SYNTHETIC_JWT',
                  );
                  expect(
                    (init['headers'] as Map)['Cookie'],
                    contains('jwt=SYNTHETIC_JWT'),
                  );
                  if (url.contains('/oga/userinfo?')) {
                    return response(url, {'data': {}});
                  }
                  expect(url, contains('/find/loanInfo/loanList'));
                  return response(url, {
                    'data': {
                      'total': 1,
                      'searchResult': [
                        {
                          'propNo': 'BOOK-SYNTHETIC',
                          'title': 'Example title',
                          'loanDate': '2026/10/01',
                          'normReturnDate': '2026/11/01',
                          'renewTimes': 1,
                        },
                      ],
                    },
                  });
                },
              )
              as Map;
      expect(
        (out['items'] as List).single,
        containsPair('bookId', 'BOOK-SYNTHETIC'),
      );
    },
  );

  test(
    'default school package harvests official WebView SSO and resumes the query in real QuickJS',
    () async {
      final fixture = WebViewFixture();
      final out = await runtime.run(
        package: school,
        capability: 'term.list',
        credentials: credentials,
        htmlStdlib: htmlStdlib,
        fetch: fixture.fetch,
        browserCall: fixture.browser,
        onLog: (_, m) => fixture.logs.add(m),
      );
      expect((out as Map)['currentTerm'], '2026-2027-1');
      expect(fixture.opened, ['https://ids.xidian.edu.cn/authserver/login']);
      expect(fixture.logs, contains('xidian_login_saved:ids'));
      expect(fixture.logs, contains('xidian_login_saved:ehall'));
      expect(fixture.busyStates, [true]);
      expect(fixture.authenticatedProbes, 2);
      expect(fixture.cookieReads, 12);
      final cached = await run('term.list', fetch: fixture.fetch);
      expect((cached as Map)['currentTerm'], '2026-2027-1');
    },
  );

  test(
    'compiled login ignores legacy public-suffix cookies and still verifies SSO',
    () async {
      seed(
        'ids',
        cookies: [
          for (final domain in ['edu.cn', 'cn'])
            {
              'name': 'LEGACY',
              'value': 'SYNTHETIC-INVALID',
              'domain': domain,
              'path': '/',
              'hostOnly': false,
              'isSecure': false,
              'isHttpOnly': true,
            },
        ],
      );
      final fixture = WebViewFixture();
      final out = await runtime.run(
        package: school,
        capability: 'generic.section',
        credentials: credentials,
        htmlStdlib: htmlStdlib,
        fetch: (url, init) {
          expect('${init['headers']}', isNot(contains('SYNTHETIC-INVALID')));
          return fixture.fetch(url, init);
        },
        browserCall: (method, args) {
          if (method == 'setCookies') {
            expect('${args['cookies']}', isNot(contains('SYNTHETIC-INVALID')));
          }
          return fixture.browser(method, args);
        },
        onLog: (_, message) => fixture.logs.add(message),
      );
      expect((out as Map)['sectionId'], 'xidian.login');
      expect(fixture.logs, contains('xidian_login_saved:ids'));
      expect(fixture.logs, contains('xidian_login_saved:ehall'));
    },
  );

  test(
    'compiled default WebView login preserves verified IDS and old business on API failure',
    () async {
      seed('ehall', data: {'marker': 'SYNTHETIC-OLD-BUSINESS'});
      final old = credentials.get('ehall', namespace: 'xidian.auth')!['value'];
      final fixture = WebViewFixture(businessFailure: true);
      await expectLater(
        runtime.run(
          package: login,
          capability: 'generic.section',
          credentials: credentials,
          htmlStdlib: htmlStdlib,
          fetch: fixture.fetch,
          browserCall: fixture.browser,
          onLog: (_, message) => fixture.logs.add(message),
        ),
        throwsA(
          isA<ScriptRunException>().having(
            (error) => error.code,
            'code',
            'source_response_invalid',
          ),
        ),
      );
      expect(credentials.get('ehall', namespace: 'xidian.auth')!['value'], old);
      final ids =
          jsonDecode(
                credentials.get('ids', namespace: 'xidian.auth')!['value']
                    as String,
              )
              as Map;
      expect(
        (ids['cookies'] as List).single,
        containsPair('value', 'SYNTHETIC-ROTATED'),
      );
      expect(fixture.logs, contains('xidian_login_saved:ids'));
      expect(fixture.logs, isNot(contains('xidian_login_saved:ehall')));
    },
  );

  test(
    'postgraduate default harvest uses its own IDS identity and academic target',
    () async {
      final pgCredentials = ScriptCredentials(
        store: store,
        schoolId: postgraduate.manifest.schoolId,
        scriptId: postgraduate.manifest.id,
        sdkVersion: postgraduate.manifest.sdkVersion,
      );
      final fixture = WebViewFixture(pg: true);
      await runtime.run(
        package: postgraduate,
        capability: 'generic.section',
        credentials: pgCredentials,
        htmlStdlib: htmlStdlib,
        fetch: fixture.fetch,
        browserCall: fixture.browser,
      );
      expect(pgCredentials.get('yjspt', namespace: 'xidian.auth'), isNotNull);
      expect(pgCredentials.get('ehall', namespace: 'xidian.auth'), isNull);
      expect(credentials.get('ids', namespace: 'xidian.auth'), isNull);
    },
  );

  test(
    'cancelled official IDS verification cannot save a pre-MFA cookie',
    () async {
      final fixture = WebViewFixture();
      await expectLater(
        runtime.run(
          package: login,
          capability: 'generic.section',
          credentials: credentials,
          htmlStdlib: htmlStdlib,
          fetch: (url, init) async =>
              throw StateError('incomplete IDS must not request business'),
          browserCall: (method, args) async {
            if (method == 'evaluate') {
              throw const ScriptRunException('invocation_cancelled');
            }
            return fixture.browser(method, args);
          },
        ),
        throwsA(isA<ScriptRunException>()),
      );
      expect(store.list(), isEmpty);
    },
  );

  test(
    'experimental password package uses native form/captcha requests and returns no secrets',
    () async {
      final fixture = PdaFixture(fresh: true);
      final out = await runtime.run(
        package: experimentalPda,
        capability: 'generic.section',
        credentials: credentials,
        htmlStdlib: htmlStdlib,
        fetch: fixture.fetch,
        browserCall: fixture.browser,
      );
      expect(fixture.opened, ['https://ids.xidian.edu.cn/authserver/login']);
      final ids =
          jsonDecode(
                credentials.get('ids', namespace: 'xidian.auth')!['value']
                    as String,
              )
              as Map;
      final business =
          jsonDecode(
                credentials.get('ehall', namespace: 'xidian.auth')!['value']
                    as String,
              )
              as Map;
      expect((ids['data'] as Map)['studentId'], 'SYNTHETIC-ACCOUNT');
      expect((business['data'] as Map)['authFlow'], 'pda');
      expect(
        (business['cookies'] as List).single,
        containsPair('isHttpOnly', true),
      );
      expect(jsonEncode(out), isNot(contains('SYNTHETIC')));
      expect(
        jsonEncode(store.list().map((entry) => entry.value).toList()),
        isNot(contains('SYNTHETIC-PASSWORD')),
      );
    },
  );

  test(
    'experimental password package retains verified IDS and old target on business failure',
    () async {
      seed('ehall', data: {'marker': 'SYNTHETIC-OLD-BUSINESS'});
      final old = credentials.get('ehall', namespace: 'xidian.auth')!['value'];
      final fixture = PdaFixture(businessFailure: true);
      await expectLater(
        runtime.run(
          package: experimentalPda,
          capability: 'generic.section',
          credentials: credentials,
          htmlStdlib: htmlStdlib,
          fetch: fixture.fetch,
          browserCall: fixture.browser,
          onLog: (_, m) => fixture.logs.add(m),
        ),
        throwsA(isA<ScriptRunException>()),
      );
      expect(credentials.get('ids', namespace: 'xidian.auth'), isNotNull);
      expect(credentials.get('ehall', namespace: 'xidian.auth')!['value'], old);
      expect(fixture.logs, contains('xidian_pda:ids_saved'));
      expect(fixture.logs, isNot(contains('xidian_pda:business_saved')));
      expect(fixture.logs.join(), isNot(contains('SYNTHETIC-GLOBAL')));
    },
  );

  test(
    'experimental password package accepts mobile IDS return without rendering the portal',
    () async {
      final fixture = PdaFixture(mobileGlobal: true);
      await runtime.run(
        package: experimentalPda,
        capability: 'generic.section',
        credentials: credentials,
        htmlStdlib: htmlStdlib,
        fetch: fixture.fetch,
        browserCall: fixture.browser,
      );
      expect(fixture.opened, isEmpty);
      expect(credentials.get('ids', namespace: 'xidian.auth'), isNotNull);
      expect(credentials.get('ehall', namespace: 'xidian.auth'), isNotNull);
    },
  );

  test(
    'school-bound packages reject role overrides before any requests',
    () async {
      var requests = 0;
      for (final package in [undergraduate, postgraduate]) {
        final facade = ScriptCredentials(
          store: store,
          schoolId: package.manifest.schoolId,
          scriptId: package.manifest.id,
          sdkVersion: package.manifest.sdkVersion,
        );
        await expectLater(
          runtime.run(
            package: package,
            capability: 'grades.list',
            params: {
              'role': package == undergraduate
                  ? 'postgraduate'
                  : 'undergraduate',
            },
            credentials: facade,
            fetch: (url, init) async {
              requests++;
              throw StateError('cross-school request');
            },
            htmlStdlib: htmlStdlib,
          ),
          throwsA(isA<ScriptRunException>()),
        );
      }
      expect(requests, 0);
      expect(store.list(), isEmpty);
      await expectLater(
        runtime.run(
          package: postgraduate,
          capability: 'grades.list',
          credentials: credentials,
          fetch: (url, init) async =>
              throw StateError('identity mismatch request'),
        ),
        throwsA(
          isA<ScriptRunException>().having(
            (e) => e.code,
            'code',
            'identity_mismatch',
          ),
        ),
      );
    },
  );

  test(
    'a pre-MFA CASTGC cannot save IDS before verification completes',
    () async {
      final fixture = PdaFixture(mfaCancelled: true);
      await expectLater(
        runtime.run(
          package: experimentalPda,
          capability: 'generic.section',
          credentials: credentials,
          htmlStdlib: htmlStdlib,
          fetch: fixture.fetch,
          browserCall: fixture.browser,
        ),
        throwsA(isA<ScriptRunException>()),
      );
      expect(credentials.get('ids', namespace: 'xidian.auth'), isNull);
      expect(credentials.get('ehall', namespace: 'xidian.auth'), isNull);
      expect(store.list(), isEmpty);
    },
  );

  test(
    'actual school packages install as two schools and isolate same-key login sessions through switch and logout',
    () async {
      final session = SessionController();
      addTearDown(session.dispose);
      await session.bootstrap();
      session.scriptStorageConsent = () async => false;
      for (final package in [undergraduate, postgraduate]) {
        await session.installTrustedScript(
          package,
          approvedDigest: package.digest,
        );
      }
      expect(session.availableSchools.map((s) => s.id).toSet(), {
        'xidian_undergraduate',
        'xidian_postgraduate',
      });
      for (final package in [undergraduateLogin, postgraduateLogin]) {
        await session.selectTrustedScriptSchool(package.manifest.id);
        expect(session.credentialCount, 0);
        final result = await session.runTrustedScript(
          package.manifest.id,
          'generic.section',
          params: {'system': 'card'},
          htmlStdlib: htmlStdlib,
          browserCall: (method, args) async {
            if (method == 'open') {
              expect(
                args['url'],
                'https://v8scan.xidian.edu.cn/home/openXDOAuth2Page',
              );
              return null;
            }
            if (method == 'evaluate') {
              await Future<void>.delayed(const Duration(milliseconds: 650));
              return {
                'ready': true,
                'data': {'openid': 'SYNTHETIC-OPENID'},
              };
            }
            if (method == 'cookies') {
              return [
                {
                  'name': 'SID',
                  'value': package.manifest.schoolId == 'xidian_postgraduate'
                      ? 'SYNTHETIC-PG'
                      : 'SYNTHETIC-UG',
                  'path': '/',
                },
              ];
            }
            throw StateError('unexpected browser call');
          },
        );
        expect(result.ok, isTrue, reason: result.reason);
        expect(session.credentialCount, 2);
      }
      session.logout();
      expect(session.credentialCount, 0);
      await session.selectTrustedScriptSchool(undergraduate.manifest.id);
      expect(session.credentialCount, 2);
    },
  );

  test(
    'pinned real QuickJS provides the asynchronous timer used for navigation backoff',
    () async {
      final json = jsonDecode(school.encode()) as Map<String, dynamic>;
      json['source'] =
          'export const capabilities={"notice.list":async()=>{await new Promise(r=>setTimeout(r,20));return {items:[],sourceSystem:typeof setTimeout+"/"+typeof clearTimeout};}};';
      final out =
          await runtime.run(
                package: ScriptPackage.parse(jsonEncode(json)),
                capability: 'notice.list',
                credentials: credentials,
                fetch: (url, init) async =>
                    throw StateError('timer must not make a network request'),
              )
              as Map;
      expect(out['sourceSystem'], 'function/function');
    },
  );
}
