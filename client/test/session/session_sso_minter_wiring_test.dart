/// L1 headless mint 会话接线（mint 闭环 M1）：debug 按选校装配 / release 不装。
///
/// 🔒 红线 #1 承重路径：仅断言 minter 是否装配与选校联动，不触凭证值。
///
///   运行：cd client && fvm flutter test test/session/session_sso_minter_wiring_test.dart
library;

import 'package:elecon/catalog/schools.dart';
import 'package:elecon/core/login/sso_mint.dart';
import 'package:elecon/core/login/sso_mint_headless.dart';
import 'package:elecon/session/session_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

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
    c.selectSchool(defaultSchool);
    expect(c.ssoMinter, isA<HeadlessSsoMinter>());
  });

  test('reset 清除自动装配的 minter', () {
    final c = SessionController();
    addTearDown(c.dispose);
    c.selectSchool(defaultSchool);
    expect(c.ssoMinter, isA<HeadlessSsoMinter>());
    c.reset();
    expect(c.ssoMinter, isNull);
  });

  test('构造注入 minter → 选校不覆盖', () {
    final stub = _StubMinter();
    final c = SessionController(ssoMinter: stub);
    addTearDown(c.dispose);
    c.selectSchool(defaultSchool);
    expect(identical(c.ssoMinter, stub), isTrue);
  });

  test('ssoMinter setter 注入后不再自动装配', () {
    final c = SessionController();
    addTearDown(c.dispose);
    c.selectSchool(defaultSchool);
    expect(c.ssoMinter, isA<HeadlessSsoMinter>());
    final stub = _StubMinter();
    c.ssoMinter = stub;
    expect(identical(c.ssoMinter, stub), isTrue);
    c.reset();
    c.selectSchool(defaultSchool);
    expect(identical(c.ssoMinter, stub), isTrue);
  });
}
