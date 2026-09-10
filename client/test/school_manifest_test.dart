import 'dart:convert';
import 'dart:typed_data';

import 'package:elecon/catalog/schools.dart';
import 'package:elecon/core/loader/bootstrap.dart';
import 'package:elecon/core/loader/bundle.dart';
import 'package:elecon/core/login/webview_login.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/school_fixture.dart';

void main() {
  // rootBundle（FlutterAssetSource）读打包 asset 需先初始化测试绑定，否则 catalog/bundle 均返回 null。
  TestWidgetsFlutterBinding.ensureInitialized();

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
          'type': 'header',
          'headerName': 'x-access-token',
        },
      },
    };

    final school = SchoolDescriptor.fromVerifiedManifest(manifest);
    expect(school.login.url, 'https://ids.example.edu/login');
    expect(school.login.brokerView.credentials['ids-cas']?.role, 'sso-master');
    expect(
      school.login.brokerView.credentials['library-session']?.headerName,
      'x-access-token',
    );
    expect(school.login.ssoMint?.services['ehall-session']?.forms, [
      SsoMintForm.headless,
      SsoMintForm.hiddenWebView,
    ]);
  });

  test('命名 header 字段畸形时 fail-closed', () {
    final manifest = <String, dynamic>{
      'adapterId': 'school-test',
      'schoolId': 'test',
      'displayName': '测试大学',
      'network': {
        'allow': ['https://api.example.edu/*'],
      },
      'login': {
        'url': 'https://api.example.edu/login',
        'navigationAllow': ['https://api.example.edu/*'],
        'success': {
          'whenUrlMatches': ['https://api.example.edu/home*'],
        },
      },
      'credentials': {
        'session': {
          'scope': ['https://api.example.edu/*'],
          'type': 'header',
          'headerName': 7,
        },
      },
      'capabilities': const <dynamic>[],
    };
    expect(
      () => SchoolDescriptor.fromVerifiedManifest(manifest),
      throwsFormatException,
    );
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
      'capabilities': [
        {'id': 'grades.list'},
      ],
    };
    expect(
      () => SchoolDescriptor.fromVerifiedManifest(manifest),
      throwsFormatException,
    );
  });

  test('仓内 XIDIAN bootstrap manifest 与核心 capability policy 一致', () async {
    const bootstrap = BootstrapBaseline(FlutterAssetSource());
    final signedCatalog = await bootstrap.catalog();
    expect(signedCatalog, isNotNull);

    final catalog =
        jsonDecode(signedCatalog!.catalogJson) as Map<String, dynamic>;
    final entries = catalog['entries'] as List<dynamic>;
    final xidian = entries.cast<Map<String, dynamic>>().singleWhere(
      (entry) => entry['adapterId'] == 'school-xidian',
    );
    final packed = await bootstrap.bundleByDigest(xidian['digest'] as String);
    expect(packed, isNotNull);

    // ⚠ **仓内 bootstrap 产物仍是 digest v1**（`{envelope, signature}` 内联内容形态）。
    //
    // v2 的封套是 `{envelopeB64, signature, blobs}` 且**严格三字段封闭**，故这份 v1 字节会在
    // `readWire` 第一步就被拒——这不是 bug，正是格式闸门在做它该做的事。要让它重新可读，
    // 必须由 owner 用**离线 YubiKey 重签**（ADR-002 §2.3：签 official 是需显式批准的物理动作，
    // 永不自动化），随后重跑 `npm run release:package` → `npm run bootstrap:sync`。
    //
    // 故此处做**条件跳过**而非硬 `skip:`：一旦 bootstrap 被重签为 v2，本测试自动恢复运行，
    // 不依赖任何人记得回来删一行。若它长期显示 skip，说明重签仪式还没做。
    if (!_isBundleV2(packed!)) {
      markTestSkipped(
        '仓内 bootstrap 产物仍是 digest v1，待 owner 离线 YubiKey 重签为 v2 后本测试自动恢复',
      );
      return;
    }

    // Catalog/bundle signature gates have dedicated tests; this locks the packaged manifest-policy shape.
    // digest v2：清单与内容分离，故取 manifest 需要 envelope + blob 表两者（`readWire` 只做
    // 格式还原，不做信任裁定——这里也**不需要**裁定，验签有它自己的专项测试）。
    final wire = readWire(packed);
    final manifest = readEnvelopeManifestJson(
      parseEnvelope(wire.envelopeBytes).envelope,
      wire.blobs,
    );
    final school = SchoolDescriptor.fromVerifiedManifest(manifest);
    final capabilityIds = (manifest['capabilities'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .map((capability) => capability['id'])
        .toSet();
    expect(
      school.capabilityCredentials.keys,
      everyElement(isIn(capabilityIds)),
    );
  });
}

/// 这份 packed 字节是否已是 digest v2（封套为严格三字段）。
bool _isBundleV2(Uint8List packed) {
  try {
    readWire(packed);
    return true;
  } on BundleFormatException {
    return false;
  }
}
