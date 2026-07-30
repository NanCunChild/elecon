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
  // 与签名 manifest 同形：capabilityCredentials 只对**已声明**的 capability 生效
  // （schools.dart 的 `_declaredCapabilityIds` 交集，71075d0 起）。凭 fixture 的
  // ehall-session 凭证驱动核心 capability policy 的凭证闸门。
  'capabilities': [
    {
      'id': 'notice.list',
      'requestGraph': 'declarative',
      'emits': {'schema': 'elecon.notice.list', 'schemaVersion': '1.0'},
    },
    {
      'id': 'grades.list',
      'requestGraph': 'imperative',
      'emits': {'schema': 'elecon.grades.list', 'schemaVersion': '1.0'},
    },
    {
      'id': 'schedule.week',
      'requestGraph': 'imperative',
      'emits': {'schema': 'elecon.schedule.week', 'schemaVersion': '1.0'},
    },
    {
      'id': 'exam.list',
      'requestGraph': 'imperative',
      'emits': {'schema': 'elecon.exam.list', 'schemaVersion': '1.0'},
    },
  ],
});
