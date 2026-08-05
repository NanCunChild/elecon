/// 响应凭证收割与投影引擎（ADR-026 §2.8 / 工程说明 §6）—— **Dart 生产实现**。
///
/// 与 `server/src/runtime/broker/response-masker.ts` **逐字节对称**，两端照同一 golden
/// （`contract/golden/broker/response-masker.json`）双跑，钉死跨端一致（ADR-001 §8）。
/// 只实现 ADR-026 交付事务里的两段**纯函数**：
///
///   Capture（收割）：从**脱敏前**响应按规则提取一个凭证敏感标量值。
///   Project（投影）：从交给 adapter 的响应里删除/替换命中值，并清理失效实体元数据。
///
/// 不含 Commit（Credential Store / opaque handle 事务）、delivery firewall 接线、host/version
/// gate——那些是后续阶段（工程说明 §9.2 step 4/5），须人工主导。本引擎假定规则**已过组合
/// 校验**（`tools/src/validator/response-masker.ts`），只保留**运行期 fail-closed**（§2.5）。
///
/// 🔒 红线 #1（凭证敏感值不进 adapter）+ 承重路径：AI 起草，须人工 + 安全清单复核，
///    不得 AI 独自闭环（AGENTS.md §1 / ADR-026 §6）。错误只进宿主诊断，绝不含原值 / 命中片段。
///
/// JSON 投影用**按位剪接**而非「解析→改树→重序列化」：只替换命中标量的源码区间，其余字节原样
/// 保留。JS 与 Dart 字符串同为 UTF-16 码元索引，故区间下标两端一致，剪接结果逐字节相同；
/// 重序列化会在数字 / 浮点 / 转义上漂移，剪接从根上回避（§2.8「具体字节由共享 golden 钉死」）。
///
/// 明文边界（A3）：body 须为传输层解码后的 UTF-8 明文；本引擎**绝不猜测编码**，非法 / 非 UTF-8
///   由传输层→Broker 边界 fail-closed。
/// 收割值语义（A5）：capture **不做数值语义**——数字 / 布尔按源码区间取文本、字符串仅反转义，
///   凭证原值逐字节保真。
library;

import 'dart:convert';

// ---- 常量（两端必须一致）----

/// body 命中值的核心固定 sentinel（ADR-026 §2.8 / 工程说明 §6）。
const String maskerSentinel = '__ELECON_MASKED__';

/// JSON 投影写入的 sentinel 字面量（合法 JSON 字符串，剪接后仍是合法 JSON）。
final String _sentinelJson = jsonEncode(maskerSentinel);

/// body 改写后须删除的实体元数据头（小写，大小写不敏感匹配）。Content-Type 保留供 adapter 解析。
const Set<String> _strippedEntityHeaders = {
  'content-length',
  'content-encoding',
  'etag',
};

/// header 提取输入上限（对齐 dataflow maxHeaderInputBytes）。
const int maxHeaderInputBytes = 4 * 1024;

/// body 提取输入上限（对齐 dataflow maxBodyInputBytes）。
const int maxBodyInputBytes = 8 * 1024 * 1024;

/// 单次收割值上限（对齐 dataflow maxHandleBytes）。
const int maxCaptureValueBytes = 64 * 1024;

/// JSON 嵌套深度上限（B2）。**超过即 fail-closed**（`capture_too_deep`）。
///
/// 目的：`_assertJson` 的平台 `jsonDecode` 是递归的，两端（V8 / Dart VM）栈深上限不同——极深
/// 嵌套 body 可致一端 `capture_not_json`、一端栈溢出，既是低成本 DoS 也留跨端分叉窗口。故在
/// 平台 parser 之前做一次**线性、非递归**的括号计深预检，两端同阈值 → 同点 fail-closed。
/// 极少数合法超深载荷不在覆盖目标内（寄希望于中转 / 合法 relay 方案）。两端常量必须一致，
/// 由 golden `json_too_deep_fail_closed` 锁定（ADR-001 §8）。
const int maxJsonDepth = 512;

/// 累计扫描预算：整个 [applyResponseMasker] 交付事务的 JSON 合法性校验与稀疏索引构造
/// **累计扫过的 code unit 数**上限；超出即 `capture_budget_exceeded` fail-closed。
///
/// 16 MiB = 2× [maxBodyInputBytes]。**抗 DoS 天花板**、非合法流量目标（校园凭证响应 KB 级远不
/// 触及）。索引按规则路径前缀稀疏保留节点，body 只扫描一次，Capture / Project 查找不再产生
/// ×rules×2 放大；header 源另由 [maxHeaderInputBytes] 单独限、不计入此预算。两端常量与计费点
/// 必须逐一致（ADR-001 §8）。
const int maxScanBudget = 16 * 1024 * 1024;

/// 累计扫描字符计数器（[applyResponseMasker] 内单实例，跨 Capture / Project 共享）。
class _ScanBudget {
  int spent = 0;
}

/// 记账 n 个已扫 code unit；累计超预算立即 fail-closed。🔒 两端计费点必须一致。
void _charge(_ScanBudget budget, int n) {
  budget.spent += n;
  if (budget.spent > maxScanBudget) {
    throw MaskerException(
      'capture_budget_exceeded',
      '累计扫描字符超过预算 $maxScanBudget',
    );
  }
}

// ---- 类型 ----

/// 脱敏**前**的响应（Capture 读它）。
class MaskerRawResponse {
  const MaskerRawResponse({
    required this.status,
    required this.headers,
    required this.body,
  });
  final int status;
  final Map<String, String> headers;
  final String body;

  static MaskerRawResponse fromJson(Map<String, dynamic> j) =>
      MaskerRawResponse(
        status: j['status'] as int,
        headers: (j['headers'] as Map).cast<String, String>(),
        body: j['body'] as String,
      );
}

/// 单条规则的 capture 声明（引擎只用 header / json 源；handle 源由 dataflow bind 承接）。
class MaskerCaptureDecl {
  const MaskerCaptureDecl({
    required this.source,
    required this.destinationKind,
    this.name,
    this.path,
    this.destinationRef,
  });
  final String source; // header | json
  final String destinationKind; // credential | redact
  final String? name;
  final String? path;
  final String? destinationRef;

  static MaskerCaptureDecl fromJson(Map<String, dynamic> j) {
    final dest = (j['destination'] as Map).cast<String, dynamic>();
    return MaskerCaptureDecl(
      source: j['source'] as String,
      name: j['name'] as String?,
      path: j['path'] as String?,
      destinationKind: dest['kind'] as String,
      destinationRef: dest['ref'] as String?,
    );
  }
}

/// 引擎可执行的 Masker 规则（`match` 由 firewall 判定，不在纯引擎内）。
class MaskerRule {
  const MaskerRule({
    required this.id,
    required this.capture,
    required this.project,
  });
  final String id;
  final MaskerCaptureDecl capture;
  final String project; // delete | replace

  static MaskerRule fromJson(Map<String, dynamic> j) => MaskerRule(
    id: j['id'] as String,
    capture: MaskerCaptureDecl.fromJson(
      (j['capture'] as Map).cast<String, dynamic>(),
    ),
    project: j['project'] as String,
  );
}

/// 一个待托管到 Credential Store 的收割值（kind=credential 才产出；redact 只投影）。
class CapturedCredential {
  const CapturedCredential({
    required this.ruleId,
    required this.ref,
    required this.value,
  });
  final String ruleId;
  final String ref;
  final String value;
}

/// 交付事务纯函数部分的产出：待提交凭证 + 投影后响应。
class MaskerOutcome {
  const MaskerOutcome({required this.captured, required this.projected});
  final List<CapturedCredential> captured;
  final MaskerRawResponse projected;
}

/// Masker 执行期错误。整条 capability fail-closed；🔒 错误只进宿主日志，绝不回流 adapter。
///
/// `key`（B5 §3.3 白名单里引擎层可得的结构化定位字段）：仅重复键场景携带重复的 sibling 键名，
/// **绝不含原值 / 命中片段**。C1 上层 catch 再补 `ruleId` / `path` 后按 ADR-024 DEV profile 发射。
class MaskerException implements Exception {
  const MaskerException(this.code, this.message, {this.key});
  final String code;
  final String message;
  final String? key;
  @override
  String toString() => 'MaskerException($code): $message';
}

int _utf8Len(String s) => utf8.encode(s).length;

/// 单次收割值上限检查，超出 fail-closed。
String _capValue(String value) {
  if (_utf8Len(value) > maxCaptureValueBytes) {
    throw MaskerException(
      'capture_value_too_large',
      '收割值超过单值上限 $maxCaptureValueBytes 字节',
    );
  }
  return value;
}

// ═══════════════════════════════════════════════════════════════════════════
// Capture ①：header 源。大小写不敏感固定头名，须恰 1 命中（schema exactly:1）。
// ═══════════════════════════════════════════════════════════════════════════

/// 从**脱敏前**响应头收割一个值。0 命中 / 多命中 / 超限一律 fail-closed（§2.5）。
String captureHeader(String name, MaskerRawResponse raw) {
  final wanted = name.toLowerCase();
  final matches = <String>[];
  raw.headers.forEach((key, value) {
    if (key.toLowerCase() == wanted) {
      if (_utf8Len(value) > maxHeaderInputBytes) {
        throw MaskerException(
          'capture_input_too_large',
          '响应头超过 $maxHeaderInputBytes 字节',
        );
      }
      matches.add(value);
    }
  });
  if (matches.isEmpty) {
    throw const MaskerException('capture_not_found', '响应头不存在');
  }
  if (matches.length > 1) {
    throw MaskerException(
      'capture_ambiguous',
      '响应头出现 ${matches.length} 次（须恰 1）',
    );
  }
  return _capValue(matches.first);
}

// ═══════════════════════════════════════════════════════════════════════════
// Capture ②：json 源。封闭 JSONPath 定位单标量；剪接同一定位器，capture / project 一致。
// ═══════════════════════════════════════════════════════════════════════════

/// 从**脱敏前**响应体 JSON 收割一个标量值（字符串反转义；数字 / 布尔取源码字面量）。
String captureJson(String path, MaskerRawResponse raw) =>
    _captureJson(path, raw, _ScanBudget());

/// 内部实现：接受跨规则共享的累计预算（finding 1）。公开的 [captureJson] 是单预算薄包装，
/// 避免把私有类型 `_ScanBudget` 暴露进公开 API。
String _captureJson(String path, MaskerRawResponse raw, _ScanBudget budget) {
  final tokens = _tokenizeJsonPath(path);
  final index = _buildJsonIndex(
    raw.body,
    tokens == null ? const [] : [tokens],
    budget,
  );
  return _captureJsonFromIndex(path, tokens, raw.body, index);
}

void _assertBodyWithinLimit(String body) {
  if (_utf8Len(body) > maxBodyInputBytes) {
    throw MaskerException(
      'capture_input_too_large',
      '响应体超过 $maxBodyInputBytes 字节',
    );
  }
}

/// 全量 JSON 合法性校验（与 dataflow「先 jsonDecode 再抽取」同口径）。只用于产出 not_json
/// 信号并确保剪接器面对合法 JSON；**不**用其重序列化（回避跨端漂移）。
/// 先做线性深度预检（B2），再交给递归的平台 parser——避免深度炸弹在 parser 内栈溢出且跨端分叉。
void _assertJson(String body, _ScanBudget budget) {
  // 深度预检 + 平台 parse 的线性成本（~body 长度）只在索引构造前计量一次。
  _charge(budget, body.length);
  _assertJsonDepth(body);
  try {
    jsonDecode(body);
  } catch (_) {
    throw const MaskerException('capture_not_json', '响应体非 JSON');
  }
}

/// B2 深度预检：线性、非递归地扫括号计深，超 [maxJsonDepth] 即 `capture_too_deep`。
/// 字符串内的 `{` / `[` / `}` / `]` 不计（用与 [_scanString] 同款 `\\ 跳两位` 转义规则跳过串）。
/// 在**尚未确认合法**的 body 上运行也安全：只计括号，畸形结构随后仍由 jsonDecode fail-closed。
void _assertJsonDepth(String body) {
  var depth = 0;
  var i = 0;
  final n = body.length;
  while (i < n) {
    final ch = body[i];
    if (ch == '"') {
      i++;
      while (i < n) {
        final c = body[i];
        if (c == r'\') {
          i += 2;
          continue;
        }
        if (c == '"') {
          i++;
          break;
        }
        i++;
      }
      continue;
    }
    if (ch == '{' || ch == '[') {
      depth++;
      if (depth > maxJsonDepth) {
        throw MaskerException('capture_too_deep', 'JSON 嵌套深度超过 $maxJsonDepth');
      }
    } else if (ch == '}' || ch == ']') {
      depth--;
    }
    i++;
  }
}

/// 与 ADR-023 runtime 同语义的封闭 JSONPath 子集：`$`、`.key`、`['key']`、`["key"]`、`[n]`。
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
        // 数组下标须为**安全整数**：超 2^53-1 时 JS `Number` 丢精 / Dart `int.parse` 抛，两端
        // 会漂移（TS→capture_not_found、Dart→逃逸非 MaskerException）。越界即视为不支持语法。
        // 2^53-1，与 TS isSafeInteger 对齐
        final n = int.tryParse(inner);
        if (n == null || n > 9007199254740991) {
          return null;
        }
        out.add(n);
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

class _JsonSpan {
  _JsonSpan(this.start, this.end);
  final int start;
  int end;
}

enum _JsonKind { object, array, scalar }

class _JsonPathTrie {
  final Map<Object, _JsonPathTrie> children = {};
}

class _JsonIndexNode extends _JsonSpan {
  _JsonIndexNode({required int start, required int end, required this.kind})
    : super(start, end);

  final _JsonKind kind;

  /// 仅对象导航层记录源码顺序中的首个重复键；查询经过该层时才 fail-closed。
  String? duplicateKey;

  /// 只保留规则路径可达的子节点，避免为 8 MiB body 构造完整 DOM。
  final Map<Object, _JsonIndexNode> children = {};
}

const Set<String> _ws = {' ', '\t', '\n', '\r'};
int _skipWs(String s, int i) {
  while (i < s.length && _ws.contains(s[i])) {
    i++;
  }
  return i;
}

/// 扫过 s[i] 起的一个 JSON 字符串，返回收尾引号后一位。s[i] 须为 `"`。
int _scanString(String s, int i) {
  var j = i + 1;
  while (j < s.length) {
    final ch = s[j];
    if (ch == r'\') {
      j += 2;
      continue;
    }
    if (ch == '"') return j + 1;
    j++;
  }
  throw const MaskerException('capture_not_json', '未终止的 JSON 字符串');
}

/// 扫过 s[i] 起的一个字面量（number / true / false / null），至分隔符或空白止。
int _scanLiteral(String s, int i) {
  var j = i;
  while (j < s.length) {
    final ch = s[j];
    if (ch == ',' || ch == ']' || ch == '}' || _ws.contains(ch)) break;
    j++;
  }
  if (j == i) throw const MaskerException('capture_not_json', '空标量');
  return j;
}

/// 扫过 s[i] 起的一个完整 JSON 值，返回其后一位。用于跳过无关兄弟或求标量区间。
int _scanValue(String s, int i) {
  if (i >= s.length) throw const MaskerException('capture_not_json', '值缺失');
  final ch = s[i];
  if (ch == '"') return _scanString(s, i);
  if (ch == '{' || ch == '[') return _scanContainer(s, i);
  return _scanLiteral(s, i);
}

/// 跳过一个对象 / 数组，尊重字符串内的括号。返回闭括号后一位。
int _scanContainer(String s, int i) {
  var depth = 0;
  var j = i;
  while (j < s.length) {
    final ch = s[j];
    if (ch == '"') {
      j = _scanString(s, j);
      continue;
    }
    if (ch == '{' || ch == '[') {
      depth++;
    } else if (ch == '}' || ch == ']') {
      depth--;
      if (depth == 0) return j + 1;
    }
    j++;
  }
  throw const MaskerException('capture_not_json', '未闭合的 JSON 容器');
}

_JsonPathTrie _newPathTrie(List<List<Object>> paths) {
  final root = _JsonPathTrie();
  for (final tokens in paths) {
    var node = root;
    for (final token in tokens) {
      node = node.children.putIfAbsent(token, _JsonPathTrie.new);
    }
  }
  return root;
}

/// 合法性校验后单次扫描 body，按全部规则路径构造稀疏源码索引。
_JsonIndexNode _buildJsonIndex(
  String body,
  List<List<Object>> paths,
  _ScanBudget budget,
) {
  _assertBodyWithinLimit(body);
  _assertJson(body, budget);
  _charge(budget, body.length); // 定位扫描每个 code unit 至多经过一次。
  return _scanIndexedValue(body, _skipWs(body, 0), _newPathTrie(paths));
}

_JsonIndexNode _scanIndexedValue(String s, int at, _JsonPathTrie trie) {
  final start = _skipWs(s, at);
  if (start >= s.length) {
    throw const MaskerException('capture_not_json', '值缺失');
  }
  final first = s[start];

  // 没有规则继续向下时只求当前值区间，不为无关子树分配索引节点。
  if (trie.children.isEmpty) {
    final kind = first == '{'
        ? _JsonKind.object
        : first == '['
        ? _JsonKind.array
        : _JsonKind.scalar;
    return _JsonIndexNode(start: start, end: _scanValue(s, start), kind: kind);
  }

  if (first == '{') {
    final node = _JsonIndexNode(
      start: start,
      end: start,
      kind: _JsonKind.object,
    );
    final seen = <String>{};
    var i = _skipWs(s, start + 1);
    if (i < s.length && s[i] == '}') {
      node.end = i + 1;
      return node;
    }
    while (true) {
      if (i >= s.length || s[i] != '"') {
        throw const MaskerException('capture_not_json', '对象键非字符串');
      }
      final keyEnd = _scanString(s, i);
      final key = _parseJsonKey(s, i, keyEnd);
      if (!seen.add(key) && node.duplicateKey == null) node.duplicateKey = key;
      i = _skipWs(s, keyEnd);
      if (i >= s.length || s[i] != ':') {
        throw const MaskerException('capture_not_json', "对象键后缺 ':'");
      }
      i = _skipWs(s, i + 1);
      final childTrie = trie.children[key];
      if (childTrie == null) {
        i = _scanValue(s, i);
      } else {
        final child = _scanIndexedValue(s, i, childTrie);
        node.children[key] = child;
        i = child.end;
      }
      i = _skipWs(s, i);
      if (i < s.length && s[i] == ',') {
        i = _skipWs(s, i + 1);
        continue;
      }
      if (i < s.length && s[i] == '}') {
        node.end = i + 1;
        return node;
      }
      throw const MaskerException('capture_not_json', '对象格式错误');
    }
  }

  if (first == '[') {
    final node = _JsonIndexNode(
      start: start,
      end: start,
      kind: _JsonKind.array,
    );
    var i = _skipWs(s, start + 1);
    if (i < s.length && s[i] == ']') {
      node.end = i + 1;
      return node;
    }
    var index = 0;
    while (true) {
      final childTrie = trie.children[index];
      if (childTrie == null) {
        i = _scanValue(s, i);
      } else {
        final child = _scanIndexedValue(s, i, childTrie);
        node.children[index] = child;
        i = child.end;
      }
      i = _skipWs(s, i);
      if (i < s.length && s[i] == ',') {
        i = _skipWs(s, i + 1);
        index++;
        continue;
      }
      if (i < s.length && s[i] == ']') {
        node.end = i + 1;
        return node;
      }
      throw const MaskerException('capture_not_json', '数组格式错误');
    }
  }

  return _JsonIndexNode(
    start: start,
    end: _scanValue(s, start),
    kind: _JsonKind.scalar,
  );
}

/// 纯索引查询；按规则顺序执行，因此错误优先级不因批量建索引而改变。
_JsonSpan _lookupJsonSpan(_JsonIndexNode index, List<Object> tokens) {
  var node = index;
  for (final token in tokens) {
    if (token is String) {
      if (node.kind != _JsonKind.object) {
        throw const MaskerException('capture_not_found', '路径期望对象');
      }
      final key = node.duplicateKey;
      if (key != null) {
        throw MaskerException('capture_duplicate_key', 'JSON 对象重复键', key: key);
      }
    } else if (node.kind != _JsonKind.array) {
      throw const MaskerException('capture_not_found', '路径期望数组');
    }
    final child = node.children[token];
    if (child == null) {
      throw MaskerException(
        'capture_not_found',
        token is String ? '键不存在' : '数组下标越界',
      );
    }
    node = child;
  }
  return _JsonSpan(node.start, node.end);
}

String _captureJsonFromIndex(
  String path,
  List<Object>? tokens,
  String body,
  _JsonIndexNode index,
) {
  if (tokens == null) {
    throw MaskerException('capture_bad_jsonpath', "不支持的 jsonpath 语法：'$path'");
  }
  final span = _lookupJsonSpan(index, tokens);
  return _capValue(_spanScalarValue(body, span.start, span.end));
}

/// 把命中区间解释为标量文本：字符串反转义；数字 / 布尔取源码字面量；对象 / 数组 / null fail-closed。
String _spanScalarValue(String s, int start, int end) {
  final first = s[start];
  if (first == '{' || first == '[') {
    throw const MaskerException('capture_not_scalar', '命中值为对象 / 数组');
  }
  if (first == '"') return _parseJsonStringToken(s.substring(start, end));
  final raw = s.substring(start, end);
  if (raw == 'null') {
    throw const MaskerException('capture_not_scalar', '命中值为 null');
  }
  return raw;
}

/// 反转义单个 JSON 字符串 token（含引号）。非法转义 fail-closed。
String _parseJsonStringToken(String token) {
  try {
    return jsonDecode(token) as String;
  } catch (_) {
    throw const MaskerException('capture_not_json', 'JSON 字符串 token 解析失败');
  }
}

/// 对象键无转义时直接取源码内部文本；仅含反斜杠时调用平台 parser 做 JSON 反转义。
String _parseJsonKey(String s, int start, int end) {
  final escapeAt = s.indexOf(r'\', start + 1);
  return escapeAt != -1 && escapeAt < end - 1
      ? _parseJsonStringToken(s.substring(start, end))
      : s.substring(start + 1, end - 1);
}

// ═══════════════════════════════════════════════════════════════════════════
// Project：删除命中头、按位剪接 body 命中标量为 sentinel、清理失效实体元数据。
// ═══════════════════════════════════════════════════════════════════════════

/// 构造 adapter-visible 投影响应。header 源规则删除整头；json 源规则把命中标量剪接为固定
/// sentinel。任一命中缺失 / 越界 / 非标量一律 fail-closed（与 Capture 同口径，纵深防御）。
/// body 被改写后删除 Content-Length / Content-Encoding / ETag（失效实体元数据）。
MaskerRawResponse projectResponse(
  List<MaskerRule> rules,
  MaskerRawResponse raw,
) => _projectResponse(rules, raw, _ScanBudget());

/// 内部实现：接受跨规则共享的累计预算（finding 1）。公开的 [projectResponse] 是单预算薄包装，
/// 避免把私有类型 `_ScanBudget` 暴露进公开 API。
MaskerRawResponse _projectResponse(
  List<MaskerRule> rules,
  MaskerRawResponse raw,
  _ScanBudget budget, {
  Map<String, List<Object>?>? tokenized,
  _JsonIndexNode? index,
}) {
  tokenized ??= _tokenizeRulePaths(rules);
  final deleteHeaders = <String>{};
  final jsonPaths = <String>[];
  for (final rule in rules) {
    switch (rule.capture.source) {
      case 'header':
        // 复核命中存在性 / 基数（与 Capture 同口径）后再登记删除。
        captureHeader(rule.capture.name ?? '', raw);
        deleteHeaders.add((rule.capture.name ?? '').toLowerCase());
      case 'json':
        jsonPaths.add(rule.capture.path ?? '');
      default:
        throw MaskerException(
          'capture_bad_source',
          "未知 capture 源 '${rule.capture.source}'",
        );
    }
  }

  var headers = _filterHeaders(raw.headers, deleteHeaders);

  var body = raw.body;
  if (jsonPaths.isNotEmpty) {
    index ??= _buildIndexForTokenized(raw.body, tokenized, budget);
    body = _spliceSentinels(raw.body, jsonPaths, tokenized, index);
    headers = _stripEntityHeaders(headers);
  }

  return MaskerRawResponse(status: raw.status, headers: headers, body: body);
}

/// 剪接：在**原始 body**上计算并排序全部区间，一次顺序拼接 sentinel，避免逐规则整包复制。
String _spliceSentinels(
  String body,
  List<String> jsonPaths,
  Map<String, List<Object>?> tokenized,
  _JsonIndexNode index,
) {
  final spans = jsonPaths.map((path) {
    final tokens = tokenized[path];
    if (tokens == null) {
      throw MaskerException('capture_bad_jsonpath', "不支持的 jsonpath 语法：'$path'");
    }
    final span = _lookupJsonSpan(index, tokens);
    _spanScalarValue(body, span.start, span.end); // 复核标量（非标量 fail-closed）
    return span;
  }).toList()..sort((a, b) => a.start - b.start);
  for (var k = 1; k < spans.length; k++) {
    if (spans[k].start < spans[k - 1].end) {
      throw const MaskerException('project_overlap', '两条 json 规则命中区间重叠');
    }
  }
  final out = StringBuffer();
  var cursor = 0;
  for (final span in spans) {
    out
      ..write(body.substring(cursor, span.start))
      ..write(_sentinelJson);
    cursor = span.end;
  }
  out.write(body.substring(cursor));
  return out.toString();
}

Map<String, List<Object>?> _tokenizeRulePaths(List<MaskerRule> rules) {
  final out = <String, List<Object>?>{};
  for (final rule in rules) {
    if (rule.capture.source == 'json') {
      final path = rule.capture.path ?? '';
      out.putIfAbsent(path, () => _tokenizeJsonPath(path));
    }
  }
  return out;
}

_JsonIndexNode _buildIndexForTokenized(
  String body,
  Map<String, List<Object>?> tokenized,
  _ScanBudget budget,
) => _buildJsonIndex(
  body,
  tokenized.values.whereType<List<Object>>().toList(),
  budget,
);

Map<String, String> _filterHeaders(
  Map<String, String> headers,
  Set<String> deleteLower,
) {
  final out = <String, String>{};
  headers.forEach((key, value) {
    if (!deleteLower.contains(key.toLowerCase())) out[key] = value;
  });
  return out;
}

Map<String, String> _stripEntityHeaders(Map<String, String> headers) {
  final out = <String, String>{};
  headers.forEach((key, value) {
    if (!_strippedEntityHeaders.contains(key.toLowerCase())) out[key] = value;
  });
  return out;
}

// ═══════════════════════════════════════════════════════════════════════════
// 事务纯函数部分：Capture 全部规则 → Project。任一步失败即抛，调用方不得交付半成品（§4.3）。
// ═══════════════════════════════════════════════════════════════════════════

/// 执行 Capture + Project 纯函数部分，返回待托管凭证与投影响应。**不**做 Commit / 注入。
/// 先对**每条**规则 Capture（redact 也收割以强制存在性），credential 目标产出待托管值；再一次
/// 性投影。任一 Capture 或 Project 抛错 → 整体 fail-closed，调用方不交付、不发下游请求。
MaskerOutcome applyResponseMasker(
  List<MaskerRule> rules,
  MaskerRawResponse raw,
) {
  final budget = _ScanBudget();
  final tokenized = _tokenizeRulePaths(rules);
  _JsonIndexNode? index;
  final captured = <CapturedCredential>[];
  for (final rule in rules) {
    late final String value;
    if (rule.capture.source == 'header') {
      value = captureHeader(rule.capture.name ?? '', raw);
    } else {
      index ??= _buildIndexForTokenized(raw.body, tokenized, budget);
      final path = rule.capture.path ?? '';
      value = _captureJsonFromIndex(path, tokenized[path], raw.body, index);
    }
    if (rule.capture.destinationKind == 'credential') {
      captured.add(
        CapturedCredential(
          ruleId: rule.id,
          ref: rule.capture.destinationRef ?? '',
          value: value,
        ),
      );
    }
  }
  final projected = _projectResponse(
    rules,
    raw,
    budget,
    tokenized: tokenized,
    index: index,
  );
  return MaskerOutcome(captured: captured, projected: projected);
}
