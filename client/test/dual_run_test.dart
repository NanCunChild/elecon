/// 双跑一致性（客户端半边）。
///
/// 客户端 QuickJS（flutter_qjs）对同一份 parser adapter + 同一份脱敏夹具，
/// 产出必须等于夹具 golden `expected`。
///
/// 这是 ADR-001 §8 双跑闸门的客户端侧：
///   - 服务端 QuickJS-wasm == expected  →  server/src/runtime/sandbox.smoke.ts 已证
///   - 客户端 QuickJS     == expected  →  本测试
///   ⟹ 传递地，客户端 == 服务端（同一引擎，零语义漂移）。
///
/// 原生库依赖：flutter_qjs 在 FLUTTER_TEST 下从 `test/build/libffiquickjs.so` 加载，
/// 该库由 flutter_qjs 自带的 cxx/QuickJS 源码经 CMake 预构建（见 client/README）。
///
///   运行：cd client && fvm flutter test test/dual_run_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:elecon/core/adapter_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

const _parserDir = '../adapters/_template/parser';

Map<String, dynamic> _readJson(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

void main() {
  setUpAll(() {
    // 原生库非纯 flutter test 自动产物；缺失时给出可操作的提示。
    if (!File('test/build/libffiquickjs.so').existsSync()) {
      fail('缺少原生库 test/build/libffiquickjs.so；先运行：tool/build_qjs_test_lib.sh');
    }
  });

  test('parser adapter：客户端 QuickJS 产出与 golden 一致', () async {
    final source = File('$_parserDir/index.js').readAsStringSync();
    final fixture = _readJson('$_parserDir/fixtures/grades.list.json');

    final data = await runParserAdapter(
      source: source,
      capability: fixture['capability'] as String,
      params: (fixture['params'] as Map).cast<String, dynamic>(),
      responses: (fixture['responses'] as Map).cast<String, dynamic>(),
      nowMs: 1700000000000, // 固定，保证确定性
    );

    expect(data, equals(fixture['expected']));
  });

  test('capability_missing：未声明的 capability 被拒', () async {
    final source = File('$_parserDir/index.js').readAsStringSync();

    await expectLater(
      runParserAdapter(
        source: source,
        capability: 'schedule.week',
        params: const {},
        responses: const {},
      ),
      throwsA(
        isA<AdapterRunException>().having(
          (e) => e.reason,
          'reason',
          AdapterFailureReason.capabilityMissing,
        ),
      ),
    );
  });

  test('async_in_parser：parser 返回 Promise 被拒', () async {
    const source =
        'export const capabilities = { "x.y": () => Promise.resolve(1) };';

    await expectLater(
      runParserAdapter(
        source: source,
        capability: 'x.y',
        params: const {},
        responses: const {},
      ),
      throwsA(
        isA<AdapterRunException>().having(
          (e) => e.reason,
          'reason',
          AdapterFailureReason.asyncInParser,
        ),
      ),
    );
  });
}
