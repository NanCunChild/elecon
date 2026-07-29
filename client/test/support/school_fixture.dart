import 'package:elecon/catalog/schools.dart';

/// 脱敏、签名 manifest 同形的学校测试夹具；生产代码不内置任何学校认证事实。
SchoolDescriptor testSchool() => SchoolDescriptor.fromVerifiedManifest({
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
    'url': 'https://ids.example.edu/login?service=portal',
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
});
