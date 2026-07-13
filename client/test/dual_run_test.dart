/// 双跑一致性（客户端半边）。
///
/// 客户端 QuickJS（flutter_qjs_next）对同一份 parser adapter + 同一份脱敏夹具，
/// 产出必须等于夹具 golden `expected`。
///
/// 这是 ADR-001 §8 双跑闸门的客户端侧：
///   - 服务端 QuickJS-wasm == expected  →  server/src/runtime/sandbox.smoke.ts 已证
///   - 客户端 QuickJS     == expected  →  本测试
///   ⟹ 传递地，客户端 == 服务端（同一引擎，零语义漂移）。
///
/// 原生库依赖：纯 flutter test 不会构建 flutter_qjs_next 原生库；先构建插件 Linux
/// example，并通过 FLUTTER_QJS_NEXT_LIBRARY 指向 libflutter_qjs_next_plugin.so。
/// 该构建脚本目前仅 Linux，故本测试在非 Linux 平台整体 skip（而非崩溃）。
///
///   运行：cd client && tool/build_qjs_test_lib.sh && FLUTTER_QJS_NEXT_LIBRARY=/path/to/libflutter_qjs_next_plugin.so fvm flutter test test/dual_run_test.dart
library;

import 'dart:io';

import 'package:elecon/core/adapter_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

import 'utils/test_utils.dart';

void main() {
  // 非 Linux：构建脚本与预编原生库仅覆盖 Linux desktop，整体跳过而非硬失败。
  final String? skip = Platform.isLinux
      ? null
      : 'dual-run 测试目前仅支持 Linux desktop（原生库构建脚本仅 Linux）';

  group('dual-run（parser, 客户端 QuickJS）', () {
    final parserDir = repoPath('adapters/_template/parser');

    setUpAll(() {
      // Linux 下原生库非纯 flutter test 自动产物；缺失时给出可操作提示。
      final lib = Platform.environment['FLUTTER_QJS_NEXT_LIBRARY'];
      if (lib == null || lib.isEmpty || !File(lib).existsSync()) {
        fail(
            '缺少 FLUTTER_QJS_NEXT_LIBRARY 指向的原生库；先运行：tool/build_qjs_test_lib.sh');
      }
    });

    test('产出与 golden 一致', () async {
      final source = File('$parserDir/index.js').readAsStringSync();
      final fixture = readJson('$parserDir/fixtures/grades.list.json');

      final data = await runParserAdapter(
        source: source,
        capability: fixture['capability'] as String,
        params: (fixture['params'] as Map).cast<String, dynamic>(),
        responses: (fixture['responses'] as Map).cast<String, dynamic>(),
        nowMs: 1700000000000, // 固定，保证确定性
      );

      expect(data, equals(fixture['expected']));
    });

    // XIDIAN notice.list：首个用 elecon:html 标准库的真实 adapter（ADR-011 §4）。
    // 客户端 QuickJS 加载与服务端**同一份** html.bundle.js，对同一脱敏 HTML 夹具的
    // 产出必须等于 golden——服务端侧由 sandbox.smoke.ts 的 testXidianNoticeList 证，
    // 两端同引擎 + 同 bundle ⟹ 零漂移（ADR-011 §2.1/§2.3）。
    test('XIDIAN notice.list：elecon:html 解析产出与 golden 一致', () async {
      final xidianDir = repoPath('adapters/school-xidian');
      final stdlibDir = repoPath('adapters/_stdlib');
      final source = File('$xidianDir/index.js').readAsStringSync();
      final htmlStdlib = File('$stdlibDir/html.bundle.js').readAsStringSync();
      final fixture = readJson('$xidianDir/fixtures/notice.list.json');

      final data = await runParserAdapter(
        source: source,
        capability: fixture['capability'] as String,
        params:
            (fixture['params'] as Map?)?.cast<String, dynamic>() ?? const {},
        responses: (fixture['responses'] as Map).cast<String, dynamic>(),
        htmlStdlib: htmlStdlib,
        nowMs: 1700000000000, // 固定，保证确定性
      );

      expect(data, equals(fixture['expected']));
    });

    // fail-closed：未注入 elecon:html 时，import 它的 adapter 必须失败（不静默放过）。
    test('elecon:html 未注入：import 该模块的 adapter 被拒', () async {
      final xidianDir = repoPath('adapters/school-xidian');
      final source = File('$xidianDir/index.js').readAsStringSync();
      final fixture = readJson('$xidianDir/fixtures/notice.list.json');

      await expectLater(
        runParserAdapter(
          source: source,
          capability: fixture['capability'] as String,
          responses: (fixture['responses'] as Map).cast<String, dynamic>(),
          // 故意不传 htmlStdlib
          nowMs: 1700000000000,
        ),
        throwsA(isA<AdapterRunException>()),
      );
    });

    // 引擎地板漂移哨兵（客户端半边）。详见 ADR-008 §3。
    test('engine-floor canary：地板内建产出与 golden 一致', () async {
      final canaryDir = repoPath('adapters/_canary/parser');
      final source = File('$canaryDir/index.js').readAsStringSync();
      final fixture = readJson('$canaryDir/fixtures/engine_floor.json');

      final data = await runParserAdapter(
        source: source,
        capability: fixture['capability'] as String,
        params: (fixture['params'] as Map).cast<String, dynamic>(),
        responses: (fixture['responses'] as Map).cast<String, dynamic>(),
        nowMs: 1700000000000,
      );

      expect(data, equals(fixture['expected']));
    });

    test('bad_export：未导出 capabilities 对象 → badExport（与服务端词表对齐）',
        () async {
      const source = 'export const notCapabilities = {};';

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
            AdapterFailureReason.badExport,
          ),
        ),
      );
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
