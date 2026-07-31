/// 信任 profile 编译期判别器基座（ADR-024 §2.1/§2.3/§5.2）单测。
///
/// 覆盖**护栏 1（fail-closed 默认 DEPLOY）**：测试环境不带
/// `--dart-define=ELECON_TRUST_PROFILE`，故 [kTrustProfile] 为缺省 `''`，
/// [kSideloadEnabled] 必须为 `false`（DEPLOY，侧载剔除）。
///
/// DEV 值 `'dev-sideload'` 的正向判定由构建矩阵冒烟覆盖（须实际带 dart-define
/// 编译），不在此纯 host 单测内；本测试只钉死「缺省 / 未识别 ⟹ DEPLOY」。
///
/// 🔒 覆盖红线 #4 判别器；与被测代码一并须人工 + 安全清单复核（不得 AI 独自闭环）。
library;

import 'package:elecon/core/trust/trust_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('缺省（无 dart-define）→ 判为 DEPLOY，侧载剔除（护栏 1 fail-closed）', () {
    expect(kTrustProfile, '', reason: '测试环境不应带 ELECON_TRUST_PROFILE');
    expect(
      kSideloadEnabled,
      isFalse,
      reason: '缺省 profile 必须 fail-closed 到 DEPLOY（侧载入口不编入）',
    );
  });

  test('唯一 DEV 侧载值常量稳定（防拼写漂移）', () {
    expect(kDevSideloadProfile, 'dev-sideload');
  });
}
