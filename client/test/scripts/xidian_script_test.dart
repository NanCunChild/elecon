// Actual compiled SDK 2 packages, synthetic school responses, real QuickJS.
import 'dart:convert';
import 'dart:io';

import 'package:elecon/core/credential/secure_store.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/scripts/runtime.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ScriptPackage school;
  late ScriptPackage login;
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
    school = ScriptPackage.parse(
      await File(
        '../school-scripts/xidian/dist/school-xidian.elecon.json',
      ).readAsString(),
    );
    login = ScriptPackage.parse(
      await File(
        '../school-scripts/xidian/dist/school-xidian-login.elecon.json',
      ).readAsString(),
    );
    htmlStdlib = await File('assets/stdlib/html.bundle.js').readAsString();
  });
  setUp(() {
    store = CredentialStore(store: InMemorySecureStore(releaseMode: false));
    credentials = ScriptCredentials(
      store: store,
      schoolId: 'xidian',
      scriptId: 'school-xidian',
      sdkVersion: 2,
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
    'source packages bind SDK 2 and separate browser login from HTTP data',
    () {
      expect(school.manifest.sdkVersion, 2);
      expect(school.manifest.version, '0.6.0');
      expect(school.manifest.browser, isFalse);
      expect(school.manifest.capabilities, hasLength(11));
      expect(login.manifest.browser, isTrue);
      expect(login.manifest.schoolId, school.manifest.schoolId);
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
    'saved PG role routes grade queries to yjspt and preserves score semantics',
    () async {
      seed('ids', data: {'role': 'postgraduate'});
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
    'browser login compiled module saves actual cookies and returns no secrets',
    () async {
      final facade = ScriptCredentials(
        store: store,
        schoolId: 'xidian',
        scriptId: login.manifest.id,
        sdkVersion: 2,
      );
      final out = await runtime.run(
        package: login,
        capability: 'generic.section',
        params: {'system': 'ehall', 'studentId': 'SYNTHETIC_UG'},
        credentials: facade,
        fetch: (url, init) async =>
            throw StateError('login uses only the visible school browser'),
        browserCall: (method, args) async {
          if (method == 'open') {
            expect(
              args['url'],
              startsWith('https://ids.xidian.edu.cn/authserver/login?'),
            );
            return null;
          }
          if (method == 'evaluate') return {'ready': true, 'data': {}};
          if (method == 'cookies') {
            return [
              {
                'name': 'SID',
                'value': 'SYNTHETIC_BROWSER_SECRET',
                'path': '/',
                'isSecure': true,
                'isHttpOnly': true,
              },
            ];
          }
          throw StateError('unexpected_browser_method');
        },
      );
      expect(jsonEncode(out), isNot(contains('SYNTHETIC_BROWSER_SECRET')));
      final saved =
          jsonDecode(
                facade.get('ehall', namespace: 'xidian.auth')!['value']
                    as String,
              )
              as Map;
      expect((saved['data'] as Map)['studentId'], 'SYNTHETIC_UG');
      expect(saved['cookies'], isNotEmpty);
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
