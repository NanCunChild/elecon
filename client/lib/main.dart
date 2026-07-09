import 'package:flutter/material.dart';

import 'core/credential/blob_store.dart';
import 'session/session_controller.dart';
import 'session/session_scope.dart';
import 'ui/onboarding/onboarding_page.dart';
import 'ui/shell/main_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const EleconApp());
}

/// §2.8 落盘目录提供者。当前返回 null（→ 内存档 M，不落盘）——path_provider 依赖
/// 受阻（见 docs/notes/build_blockers.md）。依赖恢复后改为：
/// ```dart
/// Future<BlobStore?> _blobStoreProvider() async {
///   final dir = await getApplicationSupportDirectory();      // path_provider
///   return FileBlobStore(Directory('${dir.path}/credentials'));
/// }
/// ```
/// 即点亮 S 软件档持久化（其余 §2.8 流程已接线）。
Future<BlobStore?> _blobStoreProvider() async => null;

class EleconApp extends StatefulWidget {
  const EleconApp({super.key});

  @override
  State<EleconApp> createState() => _EleconAppState();
}

class _EleconAppState extends State<EleconApp> {
  late final SessionController _session =
      SessionController(blobStoreProvider: _blobStoreProvider);

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SessionScope(
      controller: _session,
      child: MaterialApp(
        title: 'elecon',
        debugShowCheckedModeBanner: false,
        themeMode: ThemeMode.system,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff3867d6)),
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xff7da6ff),
            brightness: Brightness.dark,
          ),
        ),
        home: _BootGate(session: _session),
      ),
    );
  }
}

/// 启动引导门：先跑 [SessionController.bootstrap]（静默续用已持久化的 S 档），
/// 就绪后进 [_RootGate]。
class _BootGate extends StatefulWidget {
  const _BootGate({required this.session});

  final SessionController session;

  @override
  State<_BootGate> createState() => _BootGateState();
}

class _BootGateState extends State<_BootGate> {
  late final Future<void> _boot = widget.session.bootstrap();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _boot,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        return const _RootGate();
      },
    );
  }
}

/// 根路由闸门：未选校 → 开始面板；已选校 → 主壳。随会话状态自动切换。
class _RootGate extends StatelessWidget {
  const _RootGate();

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    return session.isConfigured ? const MainShell() : const OnboardingPage();
  }
}
