import 'package:flutter/material.dart';

import 'probe/ohos_webview_probe.dart';

/// 编译期门禁：仅 `--dart-define=OHOS_PROBE=true` 时进探针屏。
/// release 默认 false → tree-shake 把 OhosWebViewProbeApp 及其 flutter_inappwebview
/// 引用整块剔除（红线 #4/#5：探针路径不进发版二进制）。见 docs/probes/probe_001_smoke_plan.md。
const bool kOhosProbe = bool.fromEnvironment('OHOS_PROBE');

void main() {
  runApp(kOhosProbe ? const OhosWebViewProbeApp() : const EleconApp());
}

class EleconApp extends StatelessWidget {
  const EleconApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'elecon',
      theme: ThemeData(useMaterial3: true),
      home: const Scaffold(
        body: Center(child: Text('elecon — skeleton')),
      ),
    );
  }
}
