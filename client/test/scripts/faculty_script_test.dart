// ADR-050: actual packaged school modules and real QuickJS; synthetic responses.
import 'dart:convert';
import 'dart:io';

import 'package:elecon/core/credential/secure_store.dart';
import 'package:elecon/core/credential/store.dart';
import 'package:elecon/core/scripts/credentials.dart';
import 'package:elecon/core/scripts/manifest.dart';
import 'package:elecon/core/scripts/runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<ScriptPackage> packages;
  late String html;
  setUpAll(() async {
    final directory = await Directory.systemTemp.createTemp(
      'elecon-faculty-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final built = await Process.run('npm', [
      'run',
      'scripts:xidian',
      '-w',
      'tools',
      '--',
      '--out-dir',
      directory.path,
    ], workingDirectory: '..');
    expect(built.exitCode, 0, reason: '${built.stderr}');
    packages = [
      for (final role in ['undergraduate', 'postgraduate'])
        ScriptPackage.parse(
          await File(
            '${directory.path}/school-xidian-$role.elecon.json',
          ).readAsString(),
        ),
    ];
    html = await File('assets/stdlib/html.bundle.js').readAsString();
  });

  test(
    'both school packages query public faculty without credentials or browser',
    () async {
      for (final package in packages) {
        final credentials = ScriptCredentials(
          store: CredentialStore(
            store: InMemorySecureStore(releaseMode: false),
          ),
          schoolId: package.manifest.schoolId,
          scriptId: package.manifest.id,
          sdkVersion: package.manifest.sdkVersion,
        );
        var requests = 0;
        final output =
            await const TrustedScriptRuntime().run(
                  package: package,
                  capability: 'faculty.search',
                  params: {'query': '合成 & 教师', 'page': 2, 'pageSize': 10},
                  credentials: credentials,
                  htmlStdlib: html,
                  maxRequests: 1,
                  fetch: (url, init) async {
                    requests++;
                    final uri = Uri.parse(url);
                    expect(uri.host, 'faculty.xidian.edu.cn');
                    expect(uri.queryParameters['teacherName'], '合成 & 教师');
                    expect(uri.queryParameters['pageindex'], '2');
                    expect(init['redirect'], 'error');
                    expect(init['headers'] ?? {}, isEmpty);
                    return {
                      'status': 200,
                      'url': url,
                      'headers': <String, List<String>>{},
                      'body': jsonEncode({
                        'totalnum': 11,
                        'totalpage': 2,
                        'pageindex': 1,
                        'teacherData': [
                          {
                            'teacherId': 42,
                            'teacherName': '合成教师',
                            'collegeName': '合成学院',
                            'profile': '<p>合成简介</p><script>discard()</script>',
                            'url':
                                'http://faculty.xidian.edu.cn/SYNTHETIC/zh_CN/index.htm',
                          },
                        ],
                      }),
                    };
                  },
                )
                as Map;
        expect(requests, 1);
        expect(output['page'], 2);
        expect(output['hasMore'], false);
        expect((output['items'] as List).single, {
          'id': '42',
          'name': '合成教师',
          'department': '合成学院',
          'summary': '合成简介',
          'profileUrl':
              'https://faculty.xidian.edu.cn/SYNTHETIC/zh_CN/index.htm',
        });
        expect(credentials.list(), isEmpty);
      }
    },
  );
}
