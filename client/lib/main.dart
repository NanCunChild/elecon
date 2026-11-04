import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'core/adapter_service.dart';
import 'core/ai/app_functions_controller.dart';
import 'core/credential/blob_store.dart';
import 'core/credential/hardware_keystore_channel.dart';
import 'core/debug/perf_trace.dart';
import 'core/trust/trust_profile.dart' show kSideloadEnabled;
import 'l10n/gen/app_localizations.dart';
import 'session/session_controller.dart';
import 'session/session_scope.dart';
import 'session/profile_controller.dart';
import 'session/profile_scope.dart';
import 'ui/i18n/locale_options.dart';
import 'ui/ai/app_functions_scope.dart';
import 'ui/home/home_page.dart';
import 'ui/home/desktop_placeholder.dart';
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
  LicenseRegistry.addLicense(() async* {
    for (final path in [
      'assets/native/hermes/LICENSE',
      'assets/native/hermes/THIRD_PARTY_NOTICES.txt',
    ]) {
      yield LicenseEntryWithLineBreaks([
        'Hermes APPTunnel and Rust dependencies',
      ], await rootBundle.loadString(path));
    }
  });
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

/// adapter 运行时装配：app 私有目录（bundle 缓存/last-good）+ 端点 D 拉取。
/// 端点不可达时在线拉取失败，加载器退化到 last-good/bootstrap（fail-closed）。
/// base URL 由客户端自持（DEV 可 dart-define 覆盖，见 `effectiveDistributionBaseUrl`）。
Future<AdapterService?> _adapterServiceProvider() async {
  final dir = await getApplicationSupportDirectory();
  return AdapterService.production(
    supportDir: dir,
    distributionBaseUrl: effectiveDistributionBaseUrl,
    allowInsecureHttp: kDistributionOverrideActive,
  );
}

class EleconApp extends StatefulWidget {
  const EleconApp({
    super.key,
    this.startupTrace,
    this.sessionController,
    this.profileController,
    this.loginRunner = runSchoolLogin,
    this.loadHomeSnapshot,
  });

  final PerfTrace? startupTrace;
  final SessionController? sessionController;
  final ProfileController? profileController;
  final SchoolLoginRunner loginRunner;
  final CampusSnapshotLoader? loadHomeSnapshot;

  @override
  State<EleconApp> createState() => _EleconAppState();
}

class _EleconAppState extends State<EleconApp> with WidgetsBindingObserver {
  late final ProfileController _profiles;
  late final Future<void> _profilesLoad;
  late final ThemeController _theme = ThemeController();
  late final AppFunctionsController _appFunctions;

  @override
  void initState() {
    super.initState();
    _profiles =
        widget.profileController ??
        ProfileController(
          initialSession: widget.sessionController,
          blobStoreProvider: widget.sessionController == null
              ? _blobStoreProvider
              : null,
          createSession: (blobs) => SessionController(
            hardware: const BackedHardwareKeyStore(),
            blobStoreProvider: () async => blobs,
            adapterServiceProvider: _adapterServiceProvider,
          ),
        );
    WidgetsBinding.instance.addObserver(this);
    _theme.addListener(_syncScriptLocale);
    _profiles.addListener(_syncScriptLocale);
    _syncScriptLocale();
    _profilesLoad = _profiles.bootstrap();
    _appFunctions = AppFunctionsController(
      profiles: _profiles,
      channel: !kIsWeb && defaultTargetPlatform == TargetPlatform.android
          ? const MethodChannel('elecon/app_functions')
          : null,
    );
    unawaited(_theme.load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _theme.removeListener(_syncScriptLocale);
    _profiles.removeListener(_syncScriptLocale);
    _appFunctions.dispose();
    _profiles.dispose();
    _theme.dispose();
    super.dispose();
  }

  void _syncScriptLocale() {
    // A script may support languages that the core has not translated yet.
    final locale =
        resolveAppLocale(_theme.prefs.localeTag) ??
        WidgetsBinding.instance.platformDispatcher.locale;
    _profiles.active.session.scriptLocale = locale.toLanguageTag();
  }

  @override
  void didChangeLocales(List<Locale>? locales) => _syncScriptLocale();

  @override
  Widget build(BuildContext context) {
    return AppFunctionsScope(
      controller: _appFunctions,
      child: ThemeScope(
        controller: _theme,
        child: ProfileScope(
          controller: _profiles,
          child: FutureBuilder<void>(
            future: _profilesLoad,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done &&
                  !_profiles.isRestored) {
                if (kSideloadEnabled) {
                  return const MaterialApp(home: DevSideloadStartupWarning());
                }
                return const MaterialApp(
                  home: Scaffold(body: DesktopPlaceholder()),
                );
              }
              if (snapshot.hasError) {
                return MaterialApp(
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  home: Builder(
                    builder: (context) => Scaffold(
                      body: Center(
                        child: Text(
                          AppLocalizations.of(context).profilesLoadFailed,
                        ),
                      ),
                    ),
                  ),
                );
              }
              // 偏好未落盘前用默认；load 完成后 ThemeController.notify 触发重建。
              return ListenableBuilder(
                listenable: Listenable.merge([_theme, _profiles]),
                builder: (context, _) {
                  final p = _theme.prefs;
                  final session = _profiles.active.session;
                  return SessionScope(
                    controller: session,
                    child: MaterialApp(
                      key: ValueKey(_profiles.active.id),
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
                        session: session,
                        startupTrace: widget.startupTrace,
                        loginRunner: widget.loginRunner,
                        loadHomeSnapshot: widget.loadHomeSnapshot,
                      ),
                    ),
                  );
                },
              );
            },
          ),
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
        if (snapshot.connectionState != ConnectionState.done &&
            (kSideloadEnabled || !widget.session.isRestored)) {
          // DEV 侧载产物的启动页即水印页（不可关闭，见 dev_sideload_banner.dart）。
          if (kSideloadEnabled) return const DevSideloadStartupWarning();
          return const Scaffold(body: DesktopPlaceholder());
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
