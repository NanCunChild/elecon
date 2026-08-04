/// 声明式数据流执行器双跑（客户端半边，ADR-023 §2.3/§2.4）—— Dart 产出必须等于
/// `contract/golden/broker/dataflow.json` 每例 expected。
///
/// 两端一致闸门（ADR-001 §8）：
///   - 服务端 TS  == expected  →  server/src/runtime/broker/dataflow.smoke.ts 已证
///   - 客户端 Dart == expected  →  本测试
///   ⟹ 传递地，两端数据流语义（抽取/compute/注入/脱敏/拓扑）零漂移。
///
/// 纯逻辑、不经 QuickJS，故无原生库依赖、不限平台。
///
///   运行：cd client && fvm flutter test test/broker_dataflow_test.dart
///
/// 🔒 覆盖红线 #1 数据流路径；与被测代码一并须人工 + 安全清单复核（不得 AI 独自闭环）。
library;

import 'dart:convert';

import 'package:elecon/core/broker/dataflow.dart';
import 'package:flutter_test/flutter_test.dart';

import 'utils/test_utils.dart';

/// golden 句柄 {type,text|hex} → HandleValue。
HandleValue _toHandle(Map<String, dynamic> g) {
  if (g['type'] == 'bytes') return BytesHandle(_hexToBytes(g['hex'] as String));
  return TextHandle(g['text'] as String);
}

/// HandleValue → golden 可比对形（bytes 转 hex）。
Map<String, dynamic> _fromHandle(HandleValue h) => switch (h) {
  BytesHandle(:final bytes) => {'type': 'bytes', 'hex': _bytesToHex(bytes)},
  TextHandle(:final text) => {'type': 'text', 'text': text},
};

List<int> _hexToBytes(String hex) {
  final out = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    out.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return out;
}

String _bytesToHex(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

RawResponse _rawResponse(Map<String, dynamic> j) => RawResponse(
  status: j['status'] as int,
  headers: (j['headers'] as Map).cast<String, String>(),
  body: j['body'] as String,
);

/// 断言 [fn] 抛出 DataflowException 且 code 匹配。
void _expectError(void Function() fn, String code, String label) {
  try {
    fn();
    fail('$label：期望 fail-closed（$code），但未抛错');
  } on DataflowException catch (e) {
    expect(e.code, code, reason: '$label：错误码不符');
  }
}

void main() {
  final golden = readGolden('dataflow.json');
  final nowMs = golden['nowMs'] as int;

  test('golden 非空', () {
    expect((golden['ops'] as List), isNotEmpty);
  });

  group('ops（逐 op 语义 + 跨端陷阱）', () {
    for (final raw in (golden['ops'] as List).cast<Map<String, dynamic>>()) {
      test(raw['name'] as String, () {
        final args = (raw['args'] as List)
            .cast<Map<String, dynamic>>()
            .map(_toHandle)
            .toList();
        final params = (raw['params'] as Map?)?.cast<String, dynamic>();
        if (raw['error'] != null) {
          _expectError(
            () => evalOp(raw['op'] as String, args, params, nowMs),
            raw['error'] as String,
            raw['name'] as String,
          );
        } else {
          final actual = _fromHandle(
            evalOp(raw['op'] as String, args, params, nowMs),
          );
          expect(actual, equals(raw['expected']));
        }
      });
    }
  });

  group('extract（抽取 + fail-closed）', () {
    for (final raw
        in (golden['extract'] as List).cast<Map<String, dynamic>>()) {
      test(raw['name'] as String, () {
        final bind = BindDecl.fromJson(
          (raw['bind'] as Map).cast<String, dynamic>(),
        );
        final response = _rawResponse(
          (raw['response'] as Map).cast<String, dynamic>(),
        );
        if (raw['error'] != null) {
          _expectError(
            () => extractHandle(bind, response),
            raw['error'] as String,
            raw['name'] as String,
          );
        } else {
          final actual = _fromHandle(extractHandle(bind, response));
          expect(actual, equals(raw['expected']));
        }
      });
    }
  });

  group('inject（静态汇聚点 + fail-closed）', () {
    for (final raw in (golden['inject'] as List).cast<Map<String, dynamic>>()) {
      test(raw['name'] as String, () {
        final injects = (raw['injects'] as List)
            .cast<Map<String, dynamic>>()
            .map(InjectDecl.fromJson)
            .toList();
        final env = <String, HandleValue>{
          for (final e in (raw['env'] as Map).cast<String, dynamic>().entries)
            e.key: _toHandle((e.value as Map).cast<String, dynamic>()),
        };
        if (raw['error'] != null) {
          _expectError(
            () => resolveInjections(injects, env),
            raw['error'] as String,
            raw['name'] as String,
          );
        } else {
          final request = DataflowRequestDecl.fromJson(
            (raw['request'] as Map).cast<String, dynamic>(),
          );
          final effects = resolveInjections(injects, env);
          final applied = applyInjections(request, effects);
          expect({
            'url': applied.url,
            'headers': applied.headers,
          }, equals(raw['expected']));
        }
      });
    }
  });

  group('strip（回显剥离）', () {
    for (final raw in (golden['strip'] as List).cast<Map<String, dynamic>>()) {
      test(raw['name'] as String, () {
        final response = _rawResponse(
          (raw['response'] as Map).cast<String, dynamic>(),
        );
        final injected = (raw['injectedValues'] as List).cast<String>();
        final actual = stripEchoes(response, injected);
        final expected = (raw['expected'] as Map).cast<String, dynamic>();
        expect(actual.status, expected['status']);
        expect(actual.body, expected['body']);
        expect(
          actual.headers,
          equals((expected['headers'] as Map).cast<String, String>()),
        );
      });
    }
  });

  group('pipelines（bytes 编码为 text 后继续参与声明计算）', () {
    for (final raw
        in (golden['pipelines'] as List).cast<Map<String, dynamic>>()) {
      test(raw['name'] as String, () {
        final env = <String, HandleValue>{
          for (final entry
              in (raw['env'] as Map).cast<String, dynamic>().entries)
            entry.key: _toHandle(
              (entry.value as Map).cast<String, dynamic>(),
            ),
        };
        final computed = evalComputeGraph(
          env,
          (raw['computes'] as List)
              .cast<Map<String, dynamic>>()
              .map(ComputeDecl.fromJson)
              .toList(),
          nowMs,
        );
        final applied = applyInjections(
          DataflowRequestDecl.fromJson(
            (raw['request'] as Map).cast<String, dynamic>(),
          ),
          resolveInjections(
            (raw['injects'] as List)
                .cast<Map<String, dynamic>>()
                .map(InjectDecl.fromJson)
                .toList(),
            computed,
          ),
        );
        final expected = (raw['expected'] as Map).cast<String, dynamic>();
        final expectedHandles = (expected['handles'] as Map)
            .cast<String, dynamic>();
        for (final entry in expectedHandles.entries) {
          expect(
            _fromHandle(computed[entry.key]!),
            equals((entry.value as Map).cast<String, dynamic>()),
            reason: '${raw['name']} handle ${entry.key}',
          );
        }
        expect(applied.url, expected['url']);
        expect(
          applied.headers,
          equals((expected['headers'] as Map).cast<String, String>()),
        );
      });
    }
  });

  group('echoTargets（审阅 issue 1：url 回显目标含编码形）', () {
    for (final raw
        in (golden['echoTargets'] as List).cast<Map<String, dynamic>>()) {
      test(raw['name'] as String, () {
        final e = (raw['effect'] as Map).cast<String, dynamic>();
        final effect = InjectionEffect(
          into: e['into'] as String,
          at: e['at'] as String,
          name: e['name'] as String,
          value: e['value'] as String,
        );
        expect(
          injectionEchoTargets(effect),
          equals((raw['expected'] as List).cast<String>()),
        );
      });
    }
  });

  group('topo（请求依赖分层）', () {
    for (final raw in (golden['topo'] as List).cast<Map<String, dynamic>>()) {
      test(raw['name'] as String, () {
        final requests = (raw['requests'] as List)
            .cast<Map<String, dynamic>>()
            .map(DataflowRequestDecl.fromJson)
            .toList();
        final binds = (raw['binds'] as List)
            .cast<Map<String, dynamic>>()
            .map(BindDecl.fromJson)
            .toList();
        final computes = (raw['computes'] as List)
            .cast<Map<String, dynamic>>()
            .map(ComputeDecl.fromJson)
            .toList();
        final injects = (raw['injects'] as List)
            .cast<Map<String, dynamic>>()
            .map(InjectDecl.fromJson)
            .toList();
        final actual = planRequestOrder(requests, binds, computes, injects);
        final expected = (raw['expected'] as List)
            .map((l) => (l as List).cast<String>())
            .toList();
        expect(actual, equals(expected));
      });
    }
  });

  test('端到端串联：抽取→hmac→hex→注入→回显剥离', () {
    const chalBody = 'session_key=SECRETKEY0011; client_id=cust42';
    final chal = RawResponse(status: 200, headers: const {}, body: chalBody);
    final binds = [
      BindDecl(
        varName: 'key',
        from: 'chal',
        source: 'regex',
        extract: const {'pattern': r'session_key=(\w+)', 'group': 1},
      ),
      BindDecl(
        varName: 'cid',
        from: 'chal',
        source: 'regex',
        extract: const {'pattern': r'client_id=(\w+)', 'group': 1},
      ),
    ];
    final bound = <String, HandleValue>{
      for (final b in binds) b.varName: extractHandle(b, chal),
    };
    final computes = [
      const ComputeDecl(
        varName: 'mac',
        op: 'hmac-sha256',
        args: [
          ComputeArg(ref: 'key'),
          ComputeArg(ref: 'cid'),
        ],
      ),
      const ComputeDecl(
        varName: 'sig',
        op: 'hex',
        args: [ComputeArg(ref: 'mac')],
        params: {'case': 'lower'},
      ),
    ];
    final env = evalComputeGraph(bound, computes, nowMs);
    final effects = resolveInjections([
      const InjectDecl(varName: 'sig', into: 'raw', at: 'url', name: 'sig'),
    ], env);
    final applied = applyInjections(
      const DataflowRequestDecl(key: 'raw', url: 'https://h.edu.cn/api/grades'),
      effects,
    );
    expect(applied.url, startsWith('https://h.edu.cn/api/grades?sig='));
    final sig = env['sig']! as TextHandle;
    final echoed = RawResponse(
      status: 200,
      headers: const {},
      body: 'ok sig=${sig.text}',
    );
    final stripped = stripEchoes(echoed, [sig.text]);
    expect(stripped.body.contains(sig.text), isFalse);
  });

  // sanity：确保 golden 文件确实被两端读到同一份（jsonEncode 稳定）。
  test('golden 可解析', () {
    expect(jsonEncode(golden).length, greaterThan(100));
  });
}
