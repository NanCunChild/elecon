import 'package:flutter/material.dart';

import 'session/session_controller.dart';
import 'session/session_scope.dart';
import 'ui/onboarding/onboarding_page.dart';
import 'ui/shell/main_shell.dart';

void main() {
  runApp(const EleconApp());
}

class EleconApp extends StatefulWidget {
  const EleconApp({super.key});

  @override
  State<EleconApp> createState() => _EleconAppState();
}

class _EleconAppState extends State<EleconApp> {
  late final SessionController _session = SessionController();

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
        home: const _RootGate(),
      ),
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
