/// Settings → 运行时日志查看页。
///
/// release：仅网络条目（无参 URL + 状态）；debug：可切换全部 / 仅网络。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/debug/dev_log.dart';

class DevLogPage extends StatefulWidget {
  const DevLogPage({super.key, this.log});

  /// 测试可注入；默认 [DevLog.instance]。
  final DevLog? log;

  @override
  State<DevLogPage> createState() => _DevLogPageState();
}

class _DevLogPageState extends State<DevLogPage> {
  late final DevLog _log = widget.log ?? DevLog.instance;
  bool _networkOnly = !kDebugMode;

  @override
  void initState() {
    super.initState();
    _log.addListener(_onLog);
  }

  @override
  void dispose() {
    _log.removeListener(_onLog);
    super.dispose();
  }

  void _onLog() {
    if (mounted) setState(() {});
  }

  List<DevLogEntry> get _visible => _log.visible(
        only: _networkOnly ? DevLogCategory.network : null,
      );

  Future<void> _copyAll() async {
    final lines = _visible
        .map((e) => '${e.timeLabel} [${e.category.name}] ${e.message}')
        .join('\n');
    await Clipboard.setData(ClipboardData(text: lines));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制到剪贴板')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = _visible;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('运行时日志'),
        actions: [
          if (kDebugMode)
            IconButton(
              tooltip: '清空',
              onPressed: entries.isEmpty ? null : _log.clear,
              icon: const Icon(Icons.delete_outline),
            ),
          IconButton(
            tooltip: '复制可见条目',
            onPressed: entries.isEmpty ? null : _copyAll,
            icon: const Icon(Icons.copy_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (kDebugMode)
                    FilterChip(
                      label: const Text('全部'),
                      selected: !_networkOnly,
                      onSelected: (_) => setState(() => _networkOnly = false),
                    ),
                  FilterChip(
                    label: Text(kDebugMode ? '仅网络' : '网络请求'),
                    selected: _networkOnly,
                    onSelected: kDebugMode
                        ? (_) => setState(() => _networkOnly = true)
                        : null,
                  ),
                ],
              ),
            ),
          ),
          if (!kDebugMode)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '正式版仅显示无参数 URL 与成功状态，不含请求/响应内容。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: entries.isEmpty
                ? Center(
                    child: Text(
                      '暂无日志',
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: scheme.outline,
                          ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: entries.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final e = entries[i];
                      final color = e.ok == false
                          ? scheme.error
                          : e.category == DevLogCategory.network
                              ? scheme.primary
                              : scheme.onSurfaceVariant;
                      return ListTile(
                        dense: true,
                        title: Text(
                          e.message,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                fontFamily: 'monospace',
                                color: color,
                              ),
                        ),
                        subtitle: Text(
                          '${e.timeLabel} · ${e.category.name}',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
