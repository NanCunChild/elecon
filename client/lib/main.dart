import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'core/adapter_service.dart';
import 'core/credential/blob_store.dart';
import 'core/credential/hardware_keystore_channel.dart';
import 'core/debug/perf_trace.dart';
import 'core/trust/trust_profile.dart' show kSideloadEnabled;
import 'l10n/gen/app_localizations.dart';
import 'session/session_controller.dart';
import 'session/session_scope.dart';
import 'ui/i18n/locale_options.dart';
import 'ui/home/home_page.dart';
import 'ui/login/login_flow.dart';
import 'ui/onboarding/onboarding_page.dart';
import 'ui/security/dev_sideload_banner.dart'
    show DevSideloadStartupWarning, devSideloadStartupDwell;
import 'ui/security/hardware_unlock_failed_dialog.dart';
import 'ui/shell/main_shell.dart';
import 'ui/theme/app_theme.dart';
import 'ui/theme/theme_controller.dart';
import 'ui/theme/theme_scope.dart';

Future<void> main() async {
  await runEleconApp();
}

/// Starts the platform-neutral application.
///
/// Apple builds use `main_apple.dart`, which initializes and wraps the app with
/// the separately compiled liquid-glass implementation.
Future<void> runEleconApp({
  Future<void> Function()? initializePlatformUi,
  Widget Function(Widget child)? wrapApp,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  final startupTrace = PerfTrace.start('app_start');
  startupTrace.mark('flutter_binding_ready');
  startupTrace.observeFrames();
  await initializePlatformUi?.call();
  if (initializePlatformUi != null) {
    startupTrace.mark('platform_ui_ready');
  }
  final app = EleconApp(startupTrace: startupTrace);
  runApp(wrapApp?.call(app) ?? app);
}

/// §2.8 落盘目录：H/S 密文 + wrapped DEK 写入 app 私有 application support。
/// Android：allowBackup=false；iOS：excludeFromBackup（elecon/backup 通道）。
Future<BlobStore?> _blobStoreProvider() async {
  final dir = await getApplicationSupportDirectory();
  final store = FileBlobStore(Directory('${dir.path}/credentials'));
  await store.ensureDirectoryAndExcludeFromBackup();
  return store;
}

/// adapter 运行时装配：app 私有目录（bundle 缓存/last-good）+ 测试端点 D 拉取。
/// 端点内容尚未部署时在线拉取会失败，加载器退化到 last-good/bootstrap（fail-closed）。
Future<AdapterService?> _adapterServiceProvider() async {
  final dir = await getApplicationSupportDirectory();
  return AdapterService.production(
    supportDir: dir,
    distributionBaseUrl: Uri.parse(kDistributionBaseUrl),
  );
}

class EleconApp extends StatefulWidget {
  const EleconApp({
    super.key,
    this.startupTrace,
    this.sessionController,
    this.loginRunner = runSchoolLogin,
    this.loadHomeSnapshot,
  });

  final PerfTrace? startupTrace;
  final SessionController? sessionController;
  final SchoolLoginRunner loginRunner;
  final CampusSnapshotLoader? loadHomeSnapshot;

  @override
  State<EleconApp> createState() => _EleconAppState();
}

class _EleconAppState extends State<EleconApp> {
  late final SessionController _session;
  late final ThemeController _theme = ThemeController();
  late final Future<void> _themeLoad = _theme.load();

  @override
  void initState() {
    super.initState();
    _session =
        widget.sessionController ??
        SessionController(
          hardware: const BackedHardwareKeyStore(),
          blobStoreProvider: _blobStoreProvider,
          adapterServiceProvider: _adapterServiceProvider,
        );
  }

  @override
  void dispose() {
    _session.dispose();
    _theme.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ThemeScope(
      controller: _theme,
      child: SessionScope(
        controller: _session,
        child: FutureBuilder<void>(
          future: _themeLoad,
          builder: (context, _) {
            // 偏好未落盘前用默认；load 完成后 ThemeController.notify 触发重建。
            return ListenableBuilder(
              listenable: _theme,
              builder: (context, _) {
                final p = _theme.prefs;
                return MaterialApp(
                  // 任务切换器标题也走 l10n（文案单源）。
                  onGenerateTitle: (context) =>
                      AppLocalizations.of(context).appName,
                  debugShowCheckedModeBanner: false,
                  // 语言：偏好为空（默认）时传 null → 由系统语言在
                  // supportedLocales 中协商，未命中则回落模板语言 zh。
                  locale: resolveAppLocale(p.localeTag),
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  themeMode: p.themeMode,
                  theme: AppTheme.light(p),
                  darkTheme: AppTheme.dark(p),
                  home: _BootGate(
                    session: _session,
                    startupTrace: widget.startupTrace,
                    loginRunner: widget.loginRunner,
                    loadHomeSnapshot: widget.loadHomeSnapshot,
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

/// 启动引导门：先跑 [SessionController.bootstrap]（静默续用已持久化的 S 档），
/// 就绪后进 [_RootGate]。
class _BootGate extends StatefulWidget {
  const _BootGate({
    required this.session,
    required this.loginRunner,
    this.startupTrace,
    this.loadHomeSnapshot,
  });

  final SessionController session;
  final PerfTrace? startupTrace;
  final SchoolLoginRunner loginRunner;
  final CampusSnapshotLoader? loadHomeSnapshot;

  @override
  State<_BootGate> createState() => _BootGateState();
}

class _BootGateState extends State<_BootGate> {
  /// DEV 侧载产物：启动等待 = bootstrap **并行** 最小水印停留（ADR-024 §5.4）。
  /// [kSideloadEnabled] 是编译期常量 ⟹ DEPLOY 下三元的 DEV 分支是死代码，与
  /// `dev_sideload_banner.dart` 一并被 tree-shake 剔除（护栏 2）。
  late final Future<void> _boot = kSideloadEnabled
      ? Future.wait([
          widget.session.bootstrap(),
          Future<void>.delayed(devSideloadStartupDwell),
        ])
      : widget.session.bootstrap();
  var _unlockDialogShown = false;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _boot,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          // DEV 侧载产物的启动页即水印页（不可关闭，见 dev_sideload_banner.dart）。
          if (kSideloadEnabled) return const DevSideloadStartupWarning();
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        widget.startupTrace?.mark('session_bootstrap_complete');
        if (widget.session.hardwareUnlockFailed && !_unlockDialogShown) {
          _unlockDialogShown = true;
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            if (!mounted) return;
            await showHardwareUnlockFailedDialog(context);
            if (!mounted) return;
            widget.session.acknowledgeHardwareUnlockFailure();
          });
        }
        widget.startupTrace?.mark('school_page_ready');
        widget.startupTrace?.finish();
        return _RootGate(
          loginRunner: widget.loginRunner,
          loadHomeSnapshot: widget.loadHomeSnapshot,
        );
      },
    );
  }
}

/// 根路由闸门：未选校 → 开始面板；已选校 → 主壳。随会话状态自动切换。
class _RootGate extends StatelessWidget {
  const _RootGate({required this.loginRunner, this.loadHomeSnapshot});

  final SchoolLoginRunner loginRunner;
  final CampusSnapshotLoader? loadHomeSnapshot;

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    return session.isConfigured
        ? MainShell(loadHomeSnapshot: loadHomeSnapshot)
        : OnboardingPage(loginRunner: loginRunner);
  }
}
