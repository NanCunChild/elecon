/// L1 headless mint 会话接线（mint 闭环 M1）：按选校自动装配（构造注入 / setter 优先）。
///
/// 注：原 `!kDebugMode` build 门禁已按所有者授权解除（母票换票入 release，ADR-017 §4.9
/// 合规审待补，见 SessionController 类级 🔒 文档）；本套仍在 debug 下跑，只覆盖装配与
/// 选校联动，不覆盖 release 专属路径（kDebugMode 为 const，无法在测试内翻转）。
///
/// 🔒 红线 #1 承重路径：仅断言 minter 是否装配与选校联动，不触凭证值。
///
///   运行：cd client && fvm flutter test test/session/session_sso_minter_wiring_test.dart
library;

import 'package:elecon/core/login/sso_mint.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/school_fixture.dart';

class _StubMinter implements SsoMinter {
  @override
  Future<MintOutcome> mint(String targetRef) async => MintOutcome.tgcExpired;
}

void main() {
  test('debug + selectSchool(xidian) → HeadlessSsoMinter 已装配', () {
    expect(kDebugMode, isTrue, reason: '本套测试依赖 debug build');
    final c = SessionController();
    addTearDown(c.dispose);
    expect(c.ssoMinter, isNull);
    c.selectSchool(testSchool());
    expect(c.ssoMinter, isA<FallbackSsoMinter>());
  });

  test('reset 清除自动装配的 minter', () {
    final c = SessionController();
    addTearDown(c.dispose);
    c.selectSchool(testSchool());
    expect(c.ssoMinter, isA<FallbackSsoMinter>());
    c.reset();
    expect(c.ssoMinter, isNull);
  });

  test('构造注入 minter → 选校不覆盖', () {
    final stub = _StubMinter();
    final c = SessionController(ssoMinter: stub);
    addTearDown(c.dispose);
    c.selectSchool(testSchool());
    expect(identical(c.ssoMinter, stub), isTrue);
  });

  test('ssoMinter setter 注入后不再自动装配', () {
    final c = SessionController();
    addTearDown(c.dispose);
    c.selectSchool(testSchool());
    expect(c.ssoMinter, isA<FallbackSsoMinter>());
    final stub = _StubMinter();
    c.ssoMinter = stub;
    expect(identical(c.ssoMinter, stub), isTrue);
    c.reset();
    c.selectSchool(testSchool());
    expect(identical(c.ssoMinter, stub), isTrue);
  });
}
