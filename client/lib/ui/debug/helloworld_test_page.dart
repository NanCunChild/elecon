/// HelloWorld adapter 的临时端到端测试入口。
///
/// 仅由 debug 设置页进入：直接加载远端 official bundle，验证分发、验签、QuickJS、日志桥接
/// 和 app.announcement 产出。该入口不属于正式业务 UI，发布构建在运行时拒绝 direct adapter。
library;

import 'package:flutter/material.dart';

import '../../core/adapter_service.dart';
import '../../core/loader/diagnostics.dart';
import '../../session/session_scope.dart';
import '../../session/session_controller.dart';

class HelloWorldTestPage extends StatefulWidget {
  const HelloWorldTestPage({super.key});

  @override
  State<HelloWorldTestPage> createState() => _HelloWorldTestPageState();
}

class _HelloWorldTestPageState extends State<HelloWorldTestPage> {
  late Future<CapabilityRun> _run;
  late SessionController _session;
  final List<AdapterDiagnostic> _diagnostics = [];
  var _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _session = SessionScope.of(context);
    if (!_initialized) {
      _initialized = true;
      _run = _execute();
    }
  }

  Future<CapabilityRun> _execute() {
    _diagnostics.clear();
    // onLog/onDiagnostic 默认已由 SessionController 桥到 DevLog；此处只叠页面诊断列表。
    return _session.runAdapterCapability(
      adapterId: 'school-helloworld',
      capability: 'app.announcement',
      onDiagnostic: (diagnostic) {
        if (!mounted) return;
        setState(() => _diagnostics.add(diagnostic));
      },
    );
  }

  void _retry() => setState(() => _run = _execute());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('HelloWorld 通路测试')),
      body: FutureBuilder<CapabilityRun>(
        future: _run,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final result = snapshot.data;
          if (result == null || !result.ok) {
            return _TestFailure(
              result: result,
              diagnostics: _diagnostics,
              onRetry: _retry,
            );
          }
          return _HelloWorldCard(data: result.data);
        },
      ),
    );
  }
}

class _HelloWorldCard extends StatelessWidget {
  const _HelloWorldCard({required this.data});

  final Object? data;

  @override
  Widget build(BuildContext context) {
    final map = data is Map ? data! as Map : const <Object?, Object?>{};
    final items = map['items'];
    final first = items is List && items.isNotEmpty && items.first is Map
        ? items.first as Map
        : const <Object?, Object?>{};
    final title = first['title']?.toString() ?? 'HelloWorld';
    final content = first['content']?.toString() ?? 'HelloWorld';
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card.filled(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.check_circle,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '通路已打通',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(title, style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 8),
                Text(content, style: Theme.of(context).textTheme.bodyLarge),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TestFailure extends StatelessWidget {
  const _TestFailure({
    required this.result,
    required this.diagnostics,
    required this.onRetry,
  });

  final CapabilityRun? result;
  final List<AdapterDiagnostic> diagnostics;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 12),
            Text(result?.reason ?? '测试没有返回结果', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            if (diagnostics.isNotEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: diagnostics
                        .map((d) => Text(d.summary))
                        .toList(growable: false),
                  ),
                ),
              ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
