/// 声明式跨请求数据流执行器（ADR-023 §2.3/§2.4）—— **Dart 生产实现**。
///
/// 客户端是数据流的唯一生产编排方（凭证在客户端核心；服务端只做 TS golden 基准，§4）。
/// 本文件与 `server/src/runtime/broker/dataflow.ts` **逐字节对称**，两端照同一 golden
/// 向量（`contract/golden/broker/dataflow.json`）双跑（ADR-001 §8）。校验器
/// （`tools/src/validator/dataflow.ts` D1–D16）已在**声明期**保证引用闭合 / 无环 / 类型
/// 匹配 / 密钥形态 / 复杂度限额，故本执行器假定输入**已过静态校验**，只保留**运行期
/// fail-closed**（提取/匹配失败、限额、越界）——纵深防御。
///
/// 纯函数分解（与 TS 同名同序）：
///   ① extractHandle  抽取：响应 → 不透明句柄（text）。脱敏**前**求值。
///   ② evalOp         计算：封闭 op 原生执行。含 hmac/hkdf（bytes）。
///   ③ resolveInjections / applyInjections  注入：句柄 → 下游请求静态汇聚点。
///   ④ stripEchoes    脱敏：剥响应里回显的注入值（🔒 MVP 必做，堵回读）。
///   ⑤ planRequestOrder  拓扑：无依赖并发、有依赖等上游。
///
/// 🔒 红线 #1（凭证派生值 / 句柄不进 adapter）+ 承重路径：AI 起草，须人工 + 安全清单
///    复核，不得 AI 独自闭环（AGENTS.md §1 / ADR-023 §5）。
///
/// regex 回溯步数预算：MVP **延后**（owner 2026-07-24）——靠 D5 语法白名单 + 8KB 输入
/// 上限兜底，不做逐步计数。残余风险见 docs/reference/declarative_dataflow_ops.md §3。
library;

import 'dart:convert';

import 'package:cryptography/dart.dart' show DartSha256;

// ---- 限额（docs/reference/declarative_dataflow_ops.md §4；两端必须一致）----

/// 🔒 单句柄值上限（主闸门之一）。text 按 UTF-8 字节计、bytes 按字节计。
const int maxHandleBytes = 64 * 1024;

/// 🔒 全 DAG 句柄总预算（主闸门之一），超出 fail-closed。
const int maxDagHandleBytes = 4 * 1024 * 1024;

/// header 提取输入上限。
const int maxHeaderInputBytes = 4 * 1024;

/// regex 提取输入上限（超出即失败，不静默截断）。
const int maxRegexInputBytes = 8 * 1024;

/// body 提取输入上限（对齐 DEFAULT_MAX_BODY_BYTES）。
const int maxBodyInputBytes = 8 * 1024 * 1024;

// ---- 类型 ----

/// 不透明句柄的运行期值。text=Unicode 文本；bytes=原始字节。
sealed class HandleValue {
  const HandleValue();
}

class TextHandle extends HandleValue {
  const TextHandle(this.text);
  final String text;
}

class BytesHandle extends HandleValue {
  const BytesHandle(this.bytes);
  final List<int> bytes;
}

/// 数据流执行期错误。整条 capability fail-closed；🔒 错误只进宿主日志，绝不回流 adapter。
class DataflowException implements Exception {
  const DataflowException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => 'DataflowException($code): $message';
}

/// manifest bind 段一项。
class BindDecl {
  const BindDecl({
    required this.varName,
    required this.from,
    required this.source,
    required this.extract,
  });
  final String varName;
  final String from;
  final String source; // header | body | regex
  final Map<String, dynamic> extract; // name / jsonpath / pattern / group

  static BindDecl fromJson(Map<String, dynamic> j) => BindDecl(
    varName: j['var'] as String,
    from: j['from'] as String,
    source: j['source'] as String,
    extract: (j['extract'] as Map).cast<String, dynamic>(),
  );
}

/// compute 的单个位置参数：引用句柄（ref）或内联文本字面量（text），恰择其一。
class ComputeArg {
  const ComputeArg({this.ref, this.text});
  final String? ref;
  final String? text;

  static ComputeArg fromJson(Map<String, dynamic> j) =>
      ComputeArg(ref: j['ref'] as String?, text: j['text'] as String?);
}

/// compute 段一项。
class ComputeDecl {
  const ComputeDecl({
    required this.varName,
    required this.op,
    required this.args,
    this.params,
  });
  final String varName;
  final String op;
  final List<ComputeArg> args;
  final Map<String, dynamic>? params;

  static ComputeDecl fromJson(Map<String, dynamic> j) => ComputeDecl(
    varName: j['var'] as String,
    op: j['op'] as String,
    args: (j['args'] as List)
        .map((a) => ComputeArg.fromJson((a as Map).cast<String, dynamic>()))
        .toList(),
    params: (j['params'] as Map?)?.cast<String, dynamic>(),
  );
}

/// inject 段一项。
class InjectDecl {
  const InjectDecl({
    required this.varName,
    required this.into,
    required this.at,
    required this.name,
  });
  final String varName;
  final String into;
  final String at; // url | header
  final String name;

  static InjectDecl fromJson(Map<String, dynamic> j) => InjectDecl(
    varName: j['var'] as String,
    into: j['into'] as String,
    at: j['at'] as String,
    name: j['name'] as String,
  );
}

/// requests[] 一项。
class DataflowRequestDecl {
  const DataflowRequestDecl({
    required this.key,
    required this.url,
    this.method,
  });
  final String key;
  final String url;
  final String? method;

  static DataflowRequestDecl fromJson(Map<String, dynamic> j) =>
      DataflowRequestDecl(
        key: j['key'] as String,
        url: j['url'] as String,
        method: j['method'] as String?,
      );
}

/// 脱敏**前**的响应（抽取读它；含尚未剥除的 header）。
class RawResponse {
  const RawResponse({
    required this.status,
    required this.headers,
    required this.body,
  });
  final int status;
  final Map<String, String> headers;
  final String body;
}

int _utf8Len(String s) => utf8.encode(s).length;

// ═══════════════════════════════════════════════════════════════════════════
// ① 抽取（bind）：响应 → 句柄（恒 text）。脱敏前求值，只在 broker 内部。
// ═══════════════════════════════════════════════════════════════════════════

/// 从**脱敏前**响应抽取一个标量句柄。失败一律 fail-closed（决策 6）。
HandleValue extractHandle(BindDecl bind, RawResponse response) {
  switch (bind.source) {
    case 'header':
      return _extractHeader(bind, response);
    case 'body':
      return _extractBody(bind, response);
    case 'regex':
      return _extractRegex(bind, response);
    default:
      throw DataflowException('extract_bad_source', "未知抽取源 '${bind.source}'");
  }
}

HandleValue _extractHeader(BindDecl bind, RawResponse response) {
  final wanted = (bind.extract['name'] as String? ?? '').toLowerCase();
  final matches = <String>[];
  response.headers.forEach((name, value) {
    if (name.toLowerCase() == wanted) {
      if (_utf8Len(value) > maxHeaderInputBytes) {
        throw DataflowException(
          'extract_input_too_large',
          "响应头超过 $maxHeaderInputBytes 字节",
        );
      }
      matches.add(value);
    }
  });
  if (matches.isEmpty) {
    throw DataflowException(
      'extract_not_found',
      "bind '${bind.varName}'：响应头不存在",
    );
  }
  if (matches.length > 1) {
    throw DataflowException(
      'extract_ambiguous',
      "bind '${bind.varName}'：响应头出现 ${matches.length} 次（须恰 1）",
    );
  }
  return _capText(bind.varName, matches.first);
}

HandleValue _extractBody(BindDecl bind, RawResponse response) {
  if (_utf8Len(response.body) > maxBodyInputBytes) {
    throw DataflowException(
      'extract_input_too_large',
      "bind '${bind.varName}'：响应体超过 $maxBodyInputBytes 字节",
    );
  }
  Object? root;
  try {
    root = jsonDecode(response.body);
  } catch (_) {
    throw DataflowException(
      'extract_not_json',
      "bind '${bind.varName}'：响应体非 JSON",
    );
  }
  final selected = evalJsonPath(
    bind.extract['jsonpath'] as String? ?? '',
    root,
  );
  if (selected.isEmpty) {
    throw DataflowException(
      'extract_not_found',
      "bind '${bind.varName}'：jsonpath 未选中任何值",
    );
  }
  if (selected.length > 1) {
    throw DataflowException(
      'extract_ambiguous',
      "bind '${bind.varName}'：jsonpath 选中 ${selected.length} 个（须恰 1）",
    );
  }
  return _scalarToText(bind.varName, selected.first);
}

HandleValue _extractRegex(BindDecl bind, RawResponse response) {
  if (_utf8Len(response.body) > maxRegexInputBytes) {
    // 🔒 超输入上限**失败而非截断**：截断会让行为随响应大小静默改变。
    throw DataflowException(
      'extract_input_too_large',
      "bind '${bind.varName}'：regex 输入超过 $maxRegexInputBytes 字节",
    );
  }
  final RegExp re;
  try {
    re = RegExp(bind.extract['pattern'] as String? ?? '');
  } catch (e) {
    throw DataflowException(
      'extract_bad_pattern',
      "bind '${bind.varName}'：模式串非法（$e）",
    );
  }
  final m = re.firstMatch(response.body);
  if (m == null) {
    throw DataflowException(
      'extract_not_found',
      "bind '${bind.varName}'：regex 未匹配",
    );
  }
  final group = (bind.extract['group'] as int?) ?? 0;
  if (group > m.groupCount) {
    throw DataflowException(
      'extract_not_found',
      "bind '${bind.varName}'：regex group $group 越界",
    );
  }
  final captured = m.group(group);
  if (captured == null) {
    throw DataflowException(
      'extract_not_found',
      "bind '${bind.varName}'：regex group $group 未参与匹配",
    );
  }
  return _capText(bind.varName, captured);
}

/// 把标量 JSON 值转 text 句柄；对象 / 数组 / null 视为失败（无数组句柄）。
HandleValue _scalarToText(String varName, Object? value) {
  if (value is String) return _capText(varName, value);
  if (value is int) return _capText(varName, value.toString());
  if (value is double && value.isFinite)
    return _capText(varName, _numToText(value));
  if (value is bool) return _capText(varName, value ? 'true' : 'false');
  throw DataflowException('extract_not_scalar', "bind '$varName'：选中值非标量");
}

/// double → 文本，与 JS `String(number)` 对齐（整数值不带 `.0`）。
String _numToText(double v) {
  if (v == v.roundToDouble() && v.abs() < 1e21) {
    return v.toInt().toString();
  }
  return v.toString();
}

/// 单句柄上限（64 KB）检查，超出 fail-closed。
HandleValue _capText(String varName, String value) {
  if (_utf8Len(value) > maxHandleBytes) {
    throw DataflowException(
      'handle_too_large',
      "句柄 '$varName' 超过单句柄上限 $maxHandleBytes 字节",
    );
  }
  return TextHandle(value);
}

/// 极简 JSONPath 子集求值（镜像 TS）。支持 `$`、`.key`、`['key']`、`[n]`。
/// **不**支持通配 `*` / 递归 `..` / 过滤 `?()`。命中多个由上层判 ambiguous。
List<Object?> evalJsonPath(String path, Object? root) {
  final tokens = _tokenizeJsonPath(path);
  if (tokens == null) {
    throw DataflowException('extract_bad_jsonpath', "不支持的 jsonpath 语法：'$path'");
  }
  Object? cur = root;
  for (final tok in tokens) {
    if (cur == null) return const [];
    if (tok is int) {
      if (cur is! List || tok < 0 || tok >= cur.length) return const [];
      cur = cur[tok];
    } else {
      if (cur is! Map) return const [];
      if (!cur.containsKey(tok)) return const [];
      cur = cur[tok];
    }
  }
  return [cur];
}

/// 把 jsonpath 串拆成步骤（String=对象键，int=数组下标）；不支持的语法返回 null。
List<Object>? _tokenizeJsonPath(String path) {
  if (!path.startsWith(r'$')) return null;
  final out = <Object>[];
  var i = 1;
  final wordRe = RegExp(r'[A-Za-z0-9_]');
  while (i < path.length) {
    final c = path[i];
    if (c == '.') {
      i++;
      var key = '';
      while (i < path.length && wordRe.hasMatch(path[i])) {
        key += path[i];
        i++;
      }
      if (key.isEmpty) return null;
      out.add(key);
    } else if (c == '[') {
      final close = path.indexOf(']', i);
      if (close == -1) return null;
      final inner = path.substring(i + 1, close).trim();
      if (RegExp(r'^\d+$').hasMatch(inner)) {
        out.add(int.parse(inner));
      } else if (RegExp("^'[^']*'\$").hasMatch(inner) ||
          RegExp('^"[^"]*"\$').hasMatch(inner)) {
        out.add(inner.substring(1, inner.length - 1));
      } else {
        return null;
      }
      i = close + 1;
    } else {
      return null;
    }
  }
  return out;
}

// ═══════════════════════════════════════════════════════════════════════════
// ② 计算（compute）：封闭 op 词表，broker 原生执行。逐 op 语义见 dataflow_ops.md §2。
// ═══════════════════════════════════════════════════════════════════════════

List<int> _toBytes(HandleValue v) =>
    v is BytesHandle ? v.bytes : utf8.encode((v as TextHandle).text);

String _asText(HandleValue v, String opName, int pos) {
  if (v is! TextHandle) {
    throw DataflowException(
      'op_type_mismatch',
      "$opName args[$pos] 需要 text，实得 bytes",
    );
  }
  return v.text;
}

int _byteLen(HandleValue v) =>
    v is BytesHandle ? v.bytes.length : _utf8Len((v as TextHandle).text);

/// 执行单个封闭 op。[args] 已解引用为句柄值；[params] 是 op 的标量参数。
/// 假定已过静态校验，此处只做运行期语义与限额。
HandleValue evalOp(
  String op,
  List<HandleValue> args,
  Map<String, dynamic>? params,
  int nowMs,
) {
  final p = params ?? const {};
  switch (op) {
    case 'concat':
      final sb = StringBuffer();
      for (var i = 0; i < args.length; i++) {
        sb.write(_asText(args[i], 'concat', i));
      }
      return _capText('concat', sb.toString());
    case 'substring':
      final s = _asText(args[0], 'substring', 0);
      final start = p['start'] as int;
      final length = p['length'] as int;
      // 🔒 越界一律 fail-closed，不钳制（消除 JS 钳制 vs Dart 抛异常的分歧）。
      if (start + length > s.length) {
        throw DataflowException(
          'substring_out_of_range',
          "substring 越界：start=$start+length=$length > 长度 ${s.length}",
        );
      }
      return _capText('substring', s.substring(start, start + length));
    case 'base64':
      final bytes = _toBytes(args[0]);
      final out = (p['variant'] as String) == 'url'
          ? base64Url
                .encode(bytes)
                .replaceAll('=', '') // RFC 4648 §5 无填充
          : base64.encode(bytes);
      return _capText('base64', out);
    case 'hex':
      final hex = _hex(_toBytes(args[0]));
      return _capText(
        'hex',
        (p['case'] as String) == 'upper' ? hex.toUpperCase() : hex,
      );
    case 'urlencode':
      final s = _asText(args[0], 'urlencode', 0);
      return _capText(
        'urlencode',
        urlencode(s, (p['variant'] as String) == 'form'),
      );
    case 'hmac-sha256':
      final mac = _hmacSha256(_toBytes(args[0]), _toBytes(args[1]));
      return _capBytes('hmac-sha256', mac);
    case 'hkdf':
      final out = _hkdfSha256(
        ikm: _toBytes(args[0]),
        salt: _toBytes(args[1]),
        info: _toBytes(args[2]),
        length: p['length'] as int,
      );
      return _capBytes('hkdf', out);
    case 'now':
      return _capText('now', formatNow(nowMs, p['format'] as String));
    default:
      throw DataflowException('op_unknown', "未知 op '$op'");
  }
}

HandleValue _capBytes(String opName, List<int> bytes) {
  if (bytes.length > maxHandleBytes) {
    throw DataflowException(
      'handle_too_large',
      "$opName 输出超过单句柄上限 $maxHandleBytes 字节",
    );
  }
  return BytesHandle(bytes);
}

String _hex(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// RFC 3986 unreserved 之外一律 %XX（大写）；空格 component=%20 / form=+。UTF-8 逐字节。
/// **不透传** Uri.encodeComponent（其未转义集与 %20/+ 语义与本表不一致）。
String urlencode(String s, bool form) {
  final bytes = utf8.encode(s);
  final sb = StringBuffer();
  for (final b in bytes) {
    final unreserved =
        (b >= 0x41 && b <= 0x5a) ||
        (b >= 0x61 && b <= 0x7a) ||
        (b >= 0x30 && b <= 0x39) ||
        b == 0x2d ||
        b == 0x5f ||
        b == 0x2e ||
        b == 0x7e;
    if (unreserved) {
      sb.writeCharCode(b);
    } else if (b == 0x20 && form) {
      sb.write('+');
    } else {
      sb.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return sb.toString();
}

/// now 定值格式化（不读真实时钟；nowMs 由宿主喂入）。
String formatNow(int nowMs, String format) {
  if (nowMs < 0) {
    throw DataflowException(
      'now_out_of_range',
      "now：nowMs=$nowMs 不在支持范围（须 ≥0）",
    );
  }
  switch (format) {
    case 'epoch-seconds':
      return (nowMs ~/ 1000).toString();
    case 'epoch-millis':
      return nowMs.toString();
    case 'iso8601':
      // 恒带毫秒与 Z：YYYY-MM-DDTHH:MM:SS.sssZ（对齐 JS toISOString）。
      return DateTime.fromMillisecondsSinceEpoch(
        nowMs,
        isUtc: true,
      ).toIso8601String();
    default:
      throw DataflowException('now_bad_format', "now：未知 format '$format'");
  }
}

/// 求解 bind + compute 全图，返回 var → 句柄值。假定 compute 已按声明序拓扑排好
/// （validator D7 禁前向引用）；逐条按声明序求值。累计句柄字节受全 DAG 4 MB 约束。
Map<String, HandleValue> evalComputeGraph(
  Map<String, HandleValue> bound,
  List<ComputeDecl> computes,
  int nowMs,
) {
  final env = Map<String, HandleValue>.from(bound);
  var totalBytes = 0;
  for (final v in env.values) {
    totalBytes += _byteLen(v);
  }
  for (final c in computes) {
    final argVals = c.args.map((arg) {
      if (arg.text != null) return TextHandle(arg.text!) as HandleValue;
      final ref = env[arg.ref];
      if (ref == null) {
        throw DataflowException(
          'ref_undefined',
          "compute '${c.varName}'：引用 '${arg.ref}' 未定义",
        );
      }
      return ref;
    }).toList();
    final result = evalOp(c.op, argVals, c.params, nowMs);
    totalBytes += _byteLen(result);
    if (totalBytes > maxDagHandleBytes) {
      throw DataflowException(
        'dag_budget_exceeded',
        "全 DAG 句柄总字节超过 $maxDagHandleBytes（累计 $totalBytes）",
      );
    }
    env[c.varName] = result;
  }
  return env;
}

// ---- HMAC-SHA256 / HKDF-SHA256（手写，钉两端字节一致；建于 DartSha256.hashSync）----

const _sha = DartSha256();
const int _sha256BlockBytes = 64;

List<int> _sha256(List<int> data) => _sha.hashSync(data).bytes;

/// 标准 HMAC-SHA256（RFC 2104）。
List<int> _hmacSha256(List<int> key, List<int> message) {
  var k = key.length > _sha256BlockBytes ? _sha256(key) : key;
  final block = List<int>.filled(_sha256BlockBytes, 0);
  for (var i = 0; i < k.length; i++) {
    block[i] = k[i];
  }
  final ipad = List<int>.generate(_sha256BlockBytes, (i) => block[i] ^ 0x36);
  final opad = List<int>.generate(_sha256BlockBytes, (i) => block[i] ^ 0x5c);
  final inner = _sha256([...ipad, ...message]);
  return _sha256([...opad, ...inner]);
}

/// HKDF-SHA256（RFC 5869）。salt 空 → 全零 HashLen salt；length ≤ 255×32。
List<int> _hkdfSha256({
  required List<int> ikm,
  required List<int> salt,
  required List<int> info,
  required int length,
}) {
  final effSalt = salt.isEmpty ? List<int>.filled(32, 0) : salt;
  final prk = _hmacSha256(effSalt, ikm); // extract
  final out = <int>[];
  var t = <int>[];
  var counter = 1;
  while (out.length < length) {
    t = _hmacSha256(prk, [
      ...t,
      ...info,
      counter,
    ]); // expand: T(i)=HMAC(prk, T(i-1)|info|i)
    out.addAll(t);
    counter++;
  }
  return out.sublist(0, length);
}

// ═══════════════════════════════════════════════════════════════════════════
// ③ 注入（inject）：句柄 → 下游请求静态汇聚点。返回对请求的修改，不改原对象。
// ═══════════════════════════════════════════════════════════════════════════

/// 一次注入对某请求的效果：追加 query 参数或设置请求头。
class InjectionEffect {
  const InjectionEffect({
    required this.into,
    required this.at,
    required this.name,
    required this.value,
  });
  final String into;
  final String at;
  final String name;
  final String value; // 已是 text（inject 面只接受 text）
}

/// 把注入解析为效果列表。句柄须为 text（validator D9 保证；运行期兜底）。
List<InjectionEffect> resolveInjections(
  List<InjectDecl> injects,
  Map<String, HandleValue> env,
) {
  final effects = <InjectionEffect>[];
  for (final inj in injects) {
    final v = env[inj.varName];
    if (v == null) {
      // 决策 6：注入时句柄缺失 → 整条 capability fail-closed，不省略注入。
      throw DataflowException(
        'inject_missing_handle',
        "inject：句柄 '${inj.varName}' 未就绪",
      );
    }
    if (v is! TextHandle) {
      throw DataflowException(
        'inject_type_mismatch',
        "inject '${inj.varName}'：注入面只接受 text（bytes 须先 base64/hex）",
      );
    }
    effects.add(
      InjectionEffect(
        into: inj.into,
        at: inj.at,
        name: inj.name,
        value: v.text,
      ),
    );
  }
  return effects;
}

/// 应用于某请求的效果，返回新的 {url, headers}。
({String url, Map<String, String> headers}) applyInjections(
  DataflowRequestDecl request,
  List<InjectionEffect> effects, [
  Map<String, String> baseHeaders = const {},
]) {
  var url = request.url;
  final headers = Map<String, String>.from(baseHeaders);
  for (final eff in effects) {
    if (eff.into != request.key) continue;
    if (eff.at == 'url') {
      final sep = url.contains('?') ? '&' : '?';
      url += '$sep${urlencode(eff.name, false)}=${urlencode(eff.value, false)}';
    } else {
      headers[eff.name] = eff.value;
    }
  }
  return (url: url, headers: headers);
}

// ═══════════════════════════════════════════════════════════════════════════
// ④ 脱敏：剥掉响应里回显的注入值（🔒 MVP 必做，堵回读通道，ADR-023 §2.5）。
// ═══════════════════════════════════════════════════════════════════════════

/// 注入值在响应体 / 头里的回显掩码。
const String echoMask = '[stripped]';

/// 回显剥离的最短注入值长度：短于此不剥（避免误伤高频子串）。
const int echoMinLen = 8;

/// 从交给 adapter 前的响应里剥除注入值回显。broker 知道注入值真实字节，像剥 Set-Cookie
/// 一样替换为定值掩码——adapter 无从「注入猜测 → 观察回显」套值。
RawResponse stripEchoes(RawResponse response, List<String> injectedValues) {
  final targets =
      injectedValues.where((v) => v.length >= echoMinLen).toSet().toList()
        ..sort((a, b) => b.length - a.length); // 长值优先，避免短值先替换破坏长值边界
  if (targets.isEmpty) return response;
  var body = response.body;
  for (final val in targets) {
    body = body.replaceAll(val, echoMask);
  }
  final headers = <String, String>{};
  response.headers.forEach((name, value) {
    var masked = value;
    for (final val in targets) {
      masked = masked.replaceAll(val, echoMask);
    }
    headers[name] = masked;
  });
  return RawResponse(status: response.status, headers: headers, body: body);
}

// ═══════════════════════════════════════════════════════════════════════════
// ⑤ 拓扑：请求依赖分层。无依赖并发；依赖上游的排后层。
// ═══════════════════════════════════════════════════════════════════════════

/// 每个 var 可追溯到的上游 request key 集合（bind 直接给出；compute 沿引用并上游）。
Map<String, Set<String>> traceOrigins(
  List<BindDecl> binds,
  List<ComputeDecl> computes,
) {
  final origin = <String, Set<String>>{};
  for (final b in binds) {
    origin[b.varName] = {b.from};
  }
  for (final c in computes) {
    final set = <String>{};
    for (final arg in c.args) {
      if (arg.ref != null) set.addAll(origin[arg.ref] ?? const {});
    }
    origin[c.varName] = set;
  }
  return origin;
}

/// 据 bind/inject 推请求依赖，返回**分层拓扑序**：同层可并发、靠后层依赖靠前层。
/// validator D15 已静态保证无环；此处兜底：仍成环 fail-closed（不静默破环）。
List<List<String>> planRequestOrder(
  List<DataflowRequestDecl> requests,
  List<BindDecl> binds,
  List<ComputeDecl> computes,
  List<InjectDecl> injects,
) {
  final keys = requests.map((r) => r.key).toList();
  final origin = traceOrigins(binds, computes);

  final deps = <String, Set<String>>{for (final k in keys) k: <String>{}};
  for (final inj in injects) {
    final froms = origin[inj.varName] ?? const <String>{};
    final set = deps[inj.into];
    if (set != null) {
      for (final f in froms) {
        if (f != inj.into) set.add(f);
      }
    }
  }

  final remaining = keys.toSet();
  final layers = <List<String>>[];
  while (remaining.isNotEmpty) {
    final ready = remaining.where((k) {
      for (final d in deps[k] ?? const <String>{}) {
        if (remaining.contains(d)) return false;
      }
      return true;
    }).toSet();
    if (ready.isEmpty) {
      throw DataflowException(
        'request_cycle',
        "请求依赖成环，无拓扑序：${remaining.join(', ')}",
      );
    }
    final ordered = keys.where(ready.contains).toList(); // 层内保持声明序，确定性
    layers.add(ordered);
    remaining.removeAll(ordered);
  }
  return layers;
}
