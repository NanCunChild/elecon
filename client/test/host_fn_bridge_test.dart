/// flutter_qjs fork 宿主函数通道（host-fn-channel）桥接证明 —— ADR-014 落地验证。
///
/// 证明：IsolateQjs.setHostFunctions 注入的 Dart 闭包可从 JS 经 globalThis 调用，
/// 闭包返回 Future → JS Promise，JS await 拿到结果；闭包在**主 isolate** 执行
/// （worker/JS 只见序列化结果）。这是 B6b-Dart 的 ctx.fetch 异步桥接所依赖的引擎能力。
///
///   运行：cd client && fvm flutter test test/host_fn_bridge_test.dart
///
/// 🔒 触引擎能力，按 ADR-014 / AGENTS.md §1 须人工 + 安全清单复核。
library;

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('host-fn-channel（fork 扩展）', () {
    test('Dart 闭包返回 Future → JS Promise，await 往返一致', () async {
      final qjs = IsolateQjs(timeout: 5000, memoryLimit: 64 * 1024 * 1024);
      // 主 isolate 上的宿主闭包：异步、返回结构化结果。
      qjs.setHostFunctions({
        'hostEcho': (arg) async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return {'echoed': arg, 'n': 42};
        },
      });
      try {
        final result = await qjs.evaluate(
          '''
          (async () => {
            const r = await globalThis.hostEcho('hello');
            return r.echoed + ':' + r.n;
          })()
          ''',
          name: '<host-fn-bridge>',
        );
        expect(result, 'hello:42');
      } finally {
        await qjs.close();
      }
    });

    test('多次调用同一宿主函数（每次独立 await）', () async {
      final qjs = IsolateQjs(timeout: 5000, memoryLimit: 64 * 1024 * 1024);
      var calls = 0;
      qjs.setHostFunctions({
        'next': (_) async {
          calls++;
          return calls;
        },
      });
      try {
        final result = await qjs.evaluate(
          '''
          (async () => {
            const a = await globalThis.next(0);
            const b = await globalThis.next(0);
            const c = await globalThis.next(0);
            return [a, b, c].join(',');
          })()
          ''',
        );
        expect(result, '1,2,3');
        expect(calls, 3);
      } finally {
        await qjs.close();
      }
    });

    test('宿主闭包抛错 → JS Promise reject，可被 catch', () async {
      final qjs = IsolateQjs(timeout: 5000, memoryLimit: 64 * 1024 * 1024);
      qjs.setHostFunctions({
        'boom': (_) async => throw StateError('host failure'),
      });
      try {
        final result = await qjs.evaluate(
          '''
          (async () => {
            try { await globalThis.boom(0); return 'no-throw'; }
            catch (e) { return 'caught'; }
          })()
          ''',
        );
        expect(result, 'caught');
      } finally {
        await qjs.close();
      }
    });

    test('inject-once：evaluate 后再 setHostFunctions 抛 StateError', () async {
      final qjs = IsolateQjs(timeout: 5000, memoryLimit: 64 * 1024 * 1024);
      qjs.setHostFunctions({'f': (_) => 1});
      try {
        await qjs.evaluate('1 + 1');
        expect(
          () => qjs.setHostFunctions({'g': (_) => 2}),
          throwsA(isA<StateError>()),
        );
      } finally {
        await qjs.close();
      }
    });

    test('多次（evaluate 前）setHostFunctions：累积 + 同名重注册（review Minor 1）', () async {
      final qjs = IsolateQjs(timeout: 5000, memoryLimit: 64 * 1024 * 1024);
      // 累积不同 key；同名 'a' 第二次覆盖（旧 IsolateFunction 在覆盖前 dispose，不泄漏）。
      qjs.setHostFunctions({'a': (_) async => 'first', 'b': (_) async => 'B'});
      qjs.setHostFunctions({'a': (_) async => 'second'});
      try {
        final result = await qjs.evaluate('''
          (async () => (await globalThis.a(0)) + '+' + (await globalThis.b(0)))()
        ''');
        expect(result, 'second+B'); // 'a' 取最后一次注册
      } finally {
        await qjs.close();
      }
    });

    test('close() 后重用同一 IsolateQjs：再 setHostFunctions + evaluate（review Minor 2）', () async {
      final qjs = IsolateQjs(timeout: 5000, memoryLimit: 64 * 1024 * 1024);
      try {
        // 第 1 轮
        qjs.setHostFunctions({'h': (_) async => 'round1'});
        expect(await qjs.evaluate('globalThis.h(0)'), 'round1');
        await qjs.close();

        // 第 2 轮：close 重置后重新注册（新闭包、新引擎）应正常工作
        qjs.setHostFunctions({'h': (_) async => 'round2'});
        expect(await qjs.evaluate('globalThis.h(0)'), 'round2');
      } finally {
        await qjs.close();
      }
    });
  });
}
