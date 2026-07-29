import 'package:elecon/catalog/schools.dart';
import 'package:elecon/core/login/webview_login.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/school_fixture.dart';

void main() {
  test('已验签 manifest 解析登录、凭证与 forms，保留显式偏好顺序', () {
    final manifest = <String, dynamic>{
      'adapterId': 'school-xidian',
      'schoolId': 'xidian',
      'displayName': '测试大学',
      'network': {
        'allow': [
          'https://ids.example.edu/*',
          'https://portal.example.edu/*',
          'https://card.example.edu/*',
          'https://library.example.edu/*',
        ],
      },
      'login': {
        'url': 'https://ids.example.edu/login',
        'navigationAllow': [
          'https://ids.example.edu/*',
          'https://portal.example.edu/*',
          'https://card.example.edu/*',
        ],
        'success': {
          'whenUrlMatches': ['https://portal.example.edu/home*'],
        },
        'ssoMint': {
          'authEndpoint': 'https://ids.example.edu/login?service={service}',
          'services': {
            'ehall-session': {
              'service': 'https://portal.example.edu/login',
              'success': ['https://portal.example.edu/home*'],
              'forms': ['headless', 'hidden-webview'],
            },
            'card-session': {
              'service': 'https://card.example.edu/login',
              'success': ['https://card.example.edu/home*'],
            },
          },
        },
      },
      'credentials': {
        'ids-cas': {
          'scope': ['https://ids.example.edu/*'],
          'type': 'cookie',
          'role': 'sso-master',
        },
        'ehall-session': {
          'scope': ['https://portal.example.edu/*'],
          'type': 'cookie',
        },
        'card-session': {
          'scope': ['https://card.example.edu/*'],
          'type': 'query',
          'queryParam': 'openid',
        },
        'library-session': {
          'scope': ['https://library.example.edu/*'],
          'type': 'cookie',
        },
      },
    };

    final school = SchoolDescriptor.fromVerifiedManifest(manifest);
    expect(school.login.url, 'https://ids.example.edu/login');
    expect(school.login.brokerView.credentials['ids-cas']?.role, 'sso-master');
    expect(school.login.ssoMint?.services['ehall-session']?.forms, [
      SsoMintForm.headless,
      SsoMintForm.hiddenWebView,
    ]);
  });

  test('核心 capability policy 引用缺失凭证时 fail-closed', () {
    final valid = testSchool();
    final manifest = <String, dynamic>{
      'adapterId': valid.adapterId,
      'schoolId': valid.id,
      'displayName': valid.displayName,
      'network': {'allow': valid.login.brokerView.allow},
      'login': {
        'url': valid.login.url,
        'navigationAllow': valid.login.navigationAllow,
        'success': {'whenUrlMatches': valid.login.successUrlMatches},
      },
      'credentials': <String, dynamic>{},
    };
    expect(
      () => SchoolDescriptor.fromVerifiedManifest(manifest),
      throwsFormatException,
    );
  });
}
