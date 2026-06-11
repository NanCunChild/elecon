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
/// 该构建脚本目前仅 Linux，故本测试在非 Linux 平台整体 skip（而非崩溃）。
///
///   运行：cd client && tool/build_qjs_test_lib.sh && fvm flutter test test/dual_run_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:elecon/core/adapter_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

/// 从当前工作目录向上找到仓库内的某个相对目录，避免依赖 flutter test 的具体
/// CWD。找不到则回退到相对路径（flutter test 默认 CWD=client/）。
String _repoDir(String relPath) {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final candidate = Directory('${dir.path}/$relPath');
    if (candidate.existsSync()) return candidate.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return '../$relPath';
}

Map<String, dynamic> _readJson(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

void main() {
  // 非 Linux：构建脚本与预编原生库仅覆盖 Linux desktop，整体跳过而非硬失败。
  final String? skip = Platform.isLinux
      ? null
      : 'dual-run 测试目前仅支持 Linux desktop（原生库构建脚本仅 Linux）';

  group('dual-run（parser, 客户端 QuickJS）', () {
    final parserDir = _repoDir('adapters/_template/parser');

    setUpAll(() {
      // Linux 下原生库非纯 flutter test 自动产物；缺失时给出可操作提示。
      if (!File('test/build/libffiquickjs.so').existsSync()) {
        fail('缺少原生库 test/build/libffiquickjs.so；先运行：tool/build_qjs_test_lib.sh');
      }
    });

    test('产出与 golden 一致', () async {
      final source = File('$parserDir/index.js').readAsStringSync();
      final fixture = _readJson('$parserDir/fixtures/grades.list.json');

      final data = await runParserAdapter(
        source: source,
        capability: fixture['capability'] as String,
        params: (fixture['params'] as Map).cast<String, dynamic>(),
        responses: (fixture['responses'] as Map).cast<String, dynamic>(),
        nowMs: 1700000000000, // 固定，保证确定性
      );

      expect(data, equals(fixture['expected']));
    });

    // 引擎地板漂移哨兵（客户端半边）。详见 ADR-008 §3。
    test('engine-floor canary：地板内建产出与 golden 一致', () async {
      final canaryDir = _repoDir('adapters/_canary/parser');
      final source = File('$canaryDir/index.js').readAsStringSync();
      final fixture = _readJson('$canaryDir/fixtures/engine_floor.json');

      final data = await runParserAdapter(
        source: source,
        capability: fixture['capability'] as String,
        params: (fixture['params'] as Map).cast<String, dynamic>(),
        responses: (fixture['responses'] as Map).cast<String, dynamic>(),
        nowMs: 1700000000000,
      );

      expect(data, equals(fixture['expected']));
    });

    test('capability_missing：未声明的 capability 被拒', () async {
      final source = File('$parserDir/index.js').readAsStringSync();

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

    test('timeout：死循环被超时中断', () async {
      const source =
          'export const capabilities = { spin: () => { while (true) {} } };';

      await expectLater(
        runParserAdapter(
          source: source,
          capability: 'spin',
          params: const {},
          responses: const {},
          timeoutMs: 200,
        ),
        throwsA(
          isA<AdapterRunException>().having(
            (e) => e.reason,
            'reason',
            AdapterFailureReason.timeout,
          ),
        ),
      );
    });
  }, skip: skip);
}
