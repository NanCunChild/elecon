import 'package:flutter/material.dart';

import 'probe/ohos_webview_probe.dart';

/// 编译期门禁：仅 `--dart-define=OHOS_PROBE=true` 时进探针屏。
/// release 默认 false → const 折叠使探针 **Dart 代码**被 tree-shake 剔除。
/// 边界如实声明：flutter_inappwebview 作为普通 dependency，其**原生插件体**仍随
/// GeneratedPluginRegistrant 进 release 产物（无 Dart 调用入口，非红线 #4 的侧载入口）；
/// 机制级剔除跟踪 issue #78。见 docs/probes/probe_001_smoke_plan.md。
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
