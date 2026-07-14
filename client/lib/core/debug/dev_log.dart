/// 运行时日志环缓冲（Settings 可查看）。
///
/// 策略（红线 #1）：
///  - **network**：任意 build 可记；仅 [sanitizeUrlForLog] 后的无参 URL + 成败/状态码，
///    永不记 query / fragment / header / body / cookie。
///  - **runtime / 其它**：仅 [kDebugMode] 写入；release 树摇侧不依赖其内容。
///  - 日志消息本身不得含凭证值或等价物。
///
/// 🔒 观测面贴近凭证路径：AI 起草，须人工复核脱敏边界。
library;

import 'package:flutter/foundation.dart';

/// 日志类别。
enum DevLogCategory {
  /// 出站 HTTP（transport）；release 唯一可见类别。
  network,

  /// 会话 / 存储 / 收割元数据等（仅 debug）。
  runtime,

  /// WebView / 登录流程等（仅 debug）。
  webview,
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
class DevLog extends ChangeNotifier {
  DevLog({this.capacity = 500});

  static final DevLog instance = DevLog();

  final int capacity;
  final List<DevLogEntry> _entries = <DevLogEntry>[];

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

  /// 网络请求：method + 无参 URL + 可选 status / 错误摘要（不含 body）。
  void network({
    required String method,
    required String url,
    int? statusCode,
    bool? ok,
    String? error,
  }) {
    final safe = sanitizeUrlForLog(url);
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

/// 去掉 userInfo / query / fragment，只保留 scheme://host[:port]/path。
String sanitizeUrlForLog(String raw) {
  final u = Uri.tryParse(raw.trim());
  if (u == null || !u.hasScheme || u.host.isEmpty) {
    return '<invalid-url>';
  }
  final port = u.hasPort ? ':${u.port}' : '';
  final path = u.path.isEmpty ? '' : u.path;
  return '${u.scheme}://${u.host}$port$path';
}

String _shortError(String error) {
  final one = error.split('\n').first.trim();
  if (one.length <= 80) return one;
  return '${one.substring(0, 77)}...';
}
