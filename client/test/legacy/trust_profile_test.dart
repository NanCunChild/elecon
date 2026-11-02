/// 信任 profile 编译期判别器（ADR-024 §2.1/§2.3/§5.2）单测。
///
/// 本文件在**两个 profile 轮次下都会跑**，各自断言只有该轮次能证明的事：
///   - 默认轮次（无 `--dart-define`）：**护栏 1 fail-closed** —— [kTrustProfile] 为
///     缺省 `''`、[kSideloadEnabled] 必须 `false`、产物标记必须 `DEPLOY`。
///   - DEV 轮次（`--dart-define=ELECON_TRUST_PROFILE=dev-sideload`）：正向判定 ——
///     [kSideloadEnabled] 为 `true`、产物标记为 `DEV-SIDELOAD`。
///
/// 与 profile 无关的**恒等式**（值枚举语义：`kSideloadEnabled ⟺ profile == 'dev-sideload'`、
/// 标记与开关同步）在两轮都断言——这条才是判别器的定义本身，任一轮次跑歪都该红。
///
/// 🔒 覆盖红线 #4 判别器；与被测代码一并须人工 + 安全清单复核（不得 AI 独自闭环）。
library;

import 'package:elecon/core/trust/trust_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('判别器恒等式：侧载开关 ⟺ profile 恰为唯一 DEV 值（值枚举语义）', () {
    expect(kSideloadEnabled, kTrustProfile == kDevSideloadProfile);
    expect(
      kBuildProfileLabel,
      kSideloadEnabled ? 'DEV-SIDELOAD' : 'DEPLOY',
      reason: '产物标记（护栏 4b）必须与侧载开关同步，否则 gate 会验错对象',
    );
  });

  test('唯一 DEV 侧载值常量稳定（防拼写漂移）', () {
    expect(kDevSideloadProfile, 'dev-sideload');
  });

  test('侧载入口哨兵常量稳定（gate 符号 grep 的锚点，护栏 4a）', () {
    // check_release_gate.sh 对 DEPLOY 产物 grep 这个字面量。两处必须一致；
    // 改动本值须同步改 gate 脚本，否则符号断言退化为永远为真。
    expect(kSideloadEntryMarker, 'ELECON_SIDELOAD_ENTRY_A7F3');
  });

  group('DEPLOY 轮次（无 dart-define）', () {
    test('缺省 → 判为 DEPLOY，侧载剔除（护栏 1 fail-closed）', () {
      expect(kTrustProfile, '', reason: '默认轮次不应带 ELECON_TRUST_PROFILE');
      expect(
        kSideloadEnabled,
        isFalse,
        reason: '缺省 profile 必须 fail-closed 到 DEPLOY（侧载入口不编入）',
      );
      expect(kBuildProfileLabel, 'DEPLOY');
    });
  }, skip: kSideloadEnabled ? '本组只在 DEPLOY 轮次有意义' : null);

  group('DEV 轮次（--dart-define=ELECON_TRUST_PROFILE=dev-sideload）', () {
    test('显式 DEV 值 → 侧载入口编入', () {
      expect(kTrustProfile, kDevSideloadProfile);
      expect(kSideloadEnabled, isTrue);
      expect(kBuildProfileLabel, 'DEV-SIDELOAD');
    });
  }, skip: kSideloadEnabled ? null : '本组只在 DEV profile 轮次有意义');
}
