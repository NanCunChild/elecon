/// 运行时日志环缓冲（Settings 可查看）—— client 唯一观测 sink。
///
/// 策略（红线 #1；跨端约定见 `docs/reference/cross_end_logging.md`）：
///  - **network**：任意 build 可记；[redact] 为 true 时仅无参 URL + 成败/状态码，
///    永不记 header / body / cookie 值。
///  - **runtime / webview / adapter**：仅 [kDebugMode] 写入；release 丢弃。
///  - **redact**：release 恒 true；debug 默认 true，可在 DevLog 页关闭以便联调。
///  - 日志消息本身不得含凭证值或等价物（adapter `ctx.log` 亦受此约束）。
///
/// 🔒 观测面贴近凭证路径：AI 起草，须人工复核脱敏边界。
library;

import 'package:flutter/foundation.dart';

/// 日志类别。
enum DevLogCategory {
  /// 出站 HTTP（transport）；release 唯一可见类别。
  network,

  /// 会话 / 存储 / 收割元数据 / loader 等（仅 debug）。
  runtime,

  /// WebView / 登录流程等（仅 debug）。
  webview,

  /// adapter `ctx.log` 桥接（仅 debug）。
  adapter,
}

/// 单条日志。
class DevLogEntry {
  const DevLogEntry({
    required this.time,
    required this.category,
    required this.message,
    this.ok,
    this.statusCode,
  });

  final DateTime time;
  final DevLogCategory category;
  final String message;

  /// network：请求是否成功完成（HTTP 层拿到响应为 true；抛错为 false）。
  final bool? ok;
  final int? statusCode;

  String get timeLabel {
    final t = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    String three(int n) => n.toString().padLeft(3, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${three(t.millisecond)}';
  }
}

/// 环缓冲 sink；单例 [DevLog.instance]。
///
/// 生产路径（transport / session / login）应写入本 sink；UI 只订阅展示。
class DevLog extends ChangeNotifier {
  DevLog({this.capacity = 500, bool redact = true}) : _redact = redact;

  static final DevLog instance = DevLog();

  final int capacity;
  final List<DevLogEntry> _entries = <DevLogEntry>[];

  /// 是否脱敏。release 恒视为 true（[setRedact] 在非 debug 为 no-op）。
  /// debug 默认 true；关闭后 network 可保留 query、cookie 可显示原文（仅内存环缓冲）。
  bool _redact;

  bool get redact => !kDebugMode || _redact;

  /// debug 专用：关闭脱敏以便联调。release / profile 忽略。
  void setRedact(bool value) {
    if (!kDebugMode) return;
    if (_redact == value) return;
    _redact = value;
    notifyListeners();
  }

  /// 新→旧。
  List<DevLogEntry> get entries => List<DevLogEntry>.unmodifiable(_entries);

  /// release 仅 network；debug 可全量。
  List<DevLogEntry> visible({DevLogCategory? only}) {
    Iterable<DevLogEntry> it = _entries;
    if (!kDebugMode) {
      it = it.where((e) => e.category == DevLogCategory.network);
    }
    if (only != null) {
      it = it.where((e) => e.category == only);
    }
    return List<DevLogEntry>.unmodifiable(it);
  }

  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    notifyListeners();
  }

  /// 通用写入。非 network 在 release 直接丢弃。
  void log(
    DevLogCategory category,
    String message, {
    bool? ok,
    int? statusCode,
  }) {
    if (category != DevLogCategory.network && !kDebugMode) return;
    final entry = DevLogEntry(
      time: DateTime.now(),
      category: category,
      message: message,
      ok: ok,
      statusCode: statusCode,
    );
    _entries.insert(0, entry);
    while (_entries.length > capacity) {
      _entries.removeLast();
    }
    if (kDebugMode) {
      debugPrint('[dev-log/${category.name}] $message');
    }
    notifyListeners();
  }

  void runtime(String message) => log(DevLogCategory.runtime, message);

  void webview(String message) => log(DevLogCategory.webview, message);

  /// adapter `ctx.log` / 诊断摘要的默认桥接。
  void adapter(String level, String message) {
    final lvl = level.trim().isEmpty ? 'info' : level.trim();
    log(DevLogCategory.adapter, '[$lvl] $message');
  }

  /// 网络请求：method + URL（受 [redact]）+ 可选 status / 错误摘要（不含 body）。
  void network({
    required String method,
    required String url,
    int? statusCode,
    bool? ok,
    String? error,
  }) {
    final safe = formatUrlForLog(url, redact: redact);
    final m = method.toUpperCase();
    final String msg;
    if (error != null && error.isNotEmpty) {
      msg = '$m $safe → fail (${_shortError(error)})';
    } else if (statusCode != null) {
      msg = '$m $safe → $statusCode';
    } else {
      msg = '$m $safe';
    }
    log(
      DevLogCategory.network,
      msg,
      ok: ok ?? (error == null),
      statusCode: statusCode,
    );
  }
}

/// 按脱敏策略格式化 URL。
///
/// [redact] 为 true（默认 / release）：去掉 userInfo / query / fragment。
/// false（仅 debug 联调）：保留 query / fragment，仍去掉 userInfo（防 basic-auth 泄露）。
String formatUrlForLog(String raw, {bool redact = true}) {
  final u = Uri.tryParse(raw.trim());
  if (u == null || !u.hasScheme || u.host.isEmpty) {
    return '<invalid-url>';
  }
  final port = u.hasPort ? ':${u.port}' : '';
  final path = u.path.isEmpty ? '' : u.path;
  final base = '${u.scheme}://${u.host}$port$path';
  if (redact) return base;
  final q = u.hasQuery ? '?${u.query}' : '';
  final f = u.hasFragment ? '#${u.fragment}' : '';
  return '$base$q$f';
}

/// 兼容旧名：始终脱敏（无参 URL）。新代码优先 [formatUrlForLog]。
String sanitizeUrlForLog(String raw) => formatUrlForLog(raw, redact: true);

/// cookie / secret 值打码。redact=false 时返回原文（debug 联调）。
String maskCookieValue(Object? value, {bool redact = true}) {
  final s = value is String ? value : (value?.toString() ?? '');
  if (!redact) return s;
  return '<${s.length}B>';
}

String _shortError(String error) {
  final one = error.split('\n').first.trim();
  if (one.length <= 80) return one;
  return '${one.substring(0, 77)}...';
}
