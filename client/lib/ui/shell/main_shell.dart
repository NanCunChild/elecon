/// 主壳：底部导航在「首页 / 论坛 / 消息 / 设置」间切换。
///
/// Apple 构建开启液态玻璃时使用玻璃底栏；其余情况为 Material 底栏。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/scripts/manifest.dart';
import '../../core/navigation/app_shortcuts_controller.dart';
import '../../core/navigation/app_feature.dart';
import '../../core/widgets/schedule_widget_controller.dart';
import '../shortcuts/schedule_widget_scope.dart';
import '../shortcuts/app_shortcuts_scope.dart';
import '../home/shortcut_feature_page.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../session/session_scope.dart';
import '../../session/session_controller.dart';
import '../scripts/script_presenter.dart';
import '../scripts/script_input_presenter.dart';
import '../scripts/script_password_dialog.dart';
import '../scripts/script_scanner_page.dart';
import '../scripts/script_device_input_page.dart';
import '../security/no_hardware_warning_dialog.dart';
import '../home/home_page.dart';
import '../home/script_feature_page.dart';
import '../settings/settings_page.dart';
import '../theme/app_theme.dart';
import '../theme/liquid_glass.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key, this.loadHomeSnapshot});

  final CampusSnapshotLoader? loadHomeSnapshot;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  bool _suspended = false;
  String _tab = 'home';
  AppShortcutsController? _shortcuts;
  int? _scheduledShortcut;
  ScheduleWidgetController? _scheduleWidgets;
  int? _scheduledWidget;
  Object? _sourceKey;
  Future<List<_ShellPage>>? _sources;

  SessionController? _scriptSession;
  ScriptBrowserPresenter? _presenter;
  ScriptInputPresenter? _inputPresenter;
  ScriptPasswordPresenter? _passwordPresenter;
  ScriptScannerPresenter? _scannerPresenter;
  ScriptDeviceInputPresenter? _deviceInputPresenter;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(discardAbandonedScriptImages());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _scriptSession?.scriptAppForeground = true;
    }
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _scriptSession?.scriptAppForeground = false;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      // An OS picker is an authorized transient input, not background script work.
      if (_scriptSession?.scriptSystemInputPending == true) return;
      _scriptSession?.cancelTrustedScriptRuns();
      if (mounted) setState(() => _suspended = true);
    } else if (state == AppLifecycleState.resumed && mounted) {
      setState(() => _suspended = false);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _shortcuts = AppShortcutsScope.maybeOf(context);
    _scheduleWidgets = ScheduleWidgetScope.maybeOf(context);
    final session = context
        .getInheritedWidgetOfExactType<SessionScope>()
        ?.notifier;
    if (!identical(session, _scriptSession)) {
      // ADR-037 §2: a replacement controller must revoke dialogs belonging to
      // the old visible identity, even if that controller is retained elsewhere.
      _scriptSession?.cancelTrustedScriptRuns();
      if (identical(_scriptSession?.scriptBrowserPresenter, _presenter)) {
        _scriptSession?.scriptBrowserPresenter = null;
        _scriptSession?.scriptStorageConsent = null;
      }
      if (identical(_scriptSession?.scriptInputPresenter, _inputPresenter)) {
        _scriptSession?.scriptInputPresenter = null;
      }
      if (identical(
        _scriptSession?.scriptScannerPresenter,
        _scannerPresenter,
      )) {
        _scriptSession?.scriptScannerPresenter = null;
      }
      if (identical(
        _scriptSession?.scriptDeviceInputPresenter,
        _deviceInputPresenter,
      )) {
        _scriptSession?.scriptDeviceInputPresenter = null;
      }
      if (identical(
        _scriptSession?.scriptPasswordPresenter,
        _passwordPresenter,
      )) {
        _scriptSession?.scriptPasswordPresenter = null;
      }
      _scriptSession = session;
      _presenter = (package, execute) => presentScriptBrowser(
        context,
        package,
        execute,
        onCancel: session?.cancelTrustedScriptRuns,
      );
      session?.scriptBrowserPresenter = _presenter;
      _inputPresenter = (package, execute) => presentScriptInput(
        context,
        package,
        execute,
        onCancel: session?.cancelTrustedScriptRuns,
      );
      session?.scriptInputPresenter = _inputPresenter;
      _passwordPresenter = (package, request, valid) =>
          presentScriptPassword(context, request, valid);
      session?.scriptPasswordPresenter = _passwordPresenter;
      _scannerPresenter = (package, valid) =>
          presentScriptScanner(context, package, valid);
      session?.scriptScannerPresenter = _scannerPresenter;
      _deviceInputPresenter = (package, kind, valid, lease) =>
          presentScriptDeviceInput(context, package, kind, valid, lease);
      session?.scriptDeviceInputPresenter = _deviceInputPresenter;
      session?.scriptStorageConsent = () async {
        if (!mounted) return false;
        return await showNoHardwareWarningDialog(context) ==
            SoftwareStorageChoice.continueWithSoftware;
      };
    }
  }

  void _openPendingShortcut(SessionController? session) {
    final shortcuts = _shortcuts;
    final request = shortcuts?.pending;
    if (shortcuts == null ||
        !shortcuts.canOpen ||
        request == null ||
        session == null ||
        _suspended ||
        !session.isRestored ||
        !session.isConfigured ||
        session.hardwareUnlockFailed ||
        _scheduledShortcut == request.id) {
      return;
    }
    _scheduledShortcut = request.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduledShortcut = null;
      if (!mounted ||
          _suspended ||
          session.hardwareUnlockFailed ||
          !identical(session, _scriptSession) ||
          !shortcuts.consume(request)) {
        return;
      }
      Navigator.of(context).popUntil((route) => route.isFirst);
      setState(() => _tab = 'home');
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          settings: RouteSettings(name: request.feature.uri),
          builder: (_) => ShortcutFeaturePage(feature: request.feature),
        ),
      );
    });
  }

  void _openPendingWidget(SessionController? session) {
    final widgets = _scheduleWidgets;
    final request = widgets?.pending;
    if (widgets == null ||
        request == null ||
        session == null ||
        _suspended ||
        !session.isRestored ||
        !session.isConfigured ||
        session.hardwareUnlockFailed ||
        _scheduledWidget == request.serial) {
      return;
    }
    _scheduledWidget = request.serial;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduledWidget = null;
      if (!mounted ||
          _suspended ||
          session.hardwareUnlockFailed ||
          !identical(session, _scriptSession) ||
          !widgets.consume(request)) {
        return;
      }
      Navigator.of(context).popUntil((route) => route.isFirst);
      setState(() => _tab = 'home');
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => ShortcutFeaturePage(
            feature: AppFeature.schedule,
            source: request.source,
          ),
        ),
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scriptSession?.cancelTrustedScriptRuns();
    if (identical(_scriptSession?.scriptInputPresenter, _inputPresenter)) {
      _scriptSession?.scriptInputPresenter = null;
    }
    if (identical(_scriptSession?.scriptBrowserPresenter, _presenter)) {
      _scriptSession?.scriptBrowserPresenter = null;
      _scriptSession?.scriptStorageConsent = null;
    }
    if (identical(_scriptSession?.scriptScannerPresenter, _scannerPresenter)) {
      _scriptSession?.scriptScannerPresenter = null;
    }
    if (identical(
      _scriptSession?.scriptDeviceInputPresenter,
      _deviceInputPresenter,
    )) {
      _scriptSession?.scriptDeviceInputPresenter = null;
    }
    if (identical(
      _scriptSession?.scriptPasswordPresenter,
      _passwordPresenter,
    )) {
      _scriptSession?.scriptPasswordPresenter = null;
    }
    super.dispose();
  }

  static List<LiquidGlassTabSpec> _tabsOf(
    AppLocalizations l10n,
    List<_ShellPage> pages,
  ) => [
    LiquidGlassTabSpec(
      label: l10n.navHome,
      icon: Icons.home_outlined,
      selectedIcon: Icons.home,
    ),
    for (final entry in pages)
      LiquidGlassTabSpec(
        label: entry.legacy
            ? entry.page.template == 'forum'
                  ? l10n.navForum
                  : l10n.navMessages
            : entry.page.title,
        icon: scriptPageIcon(entry.page.template),
        selectedIcon: scriptPageIcon(entry.page.template),
      ),
    LiquidGlassTabSpec(
      label: l10n.navSettings,
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final session = context
        .dependOnInheritedWidgetOfExactType<SessionScope>()
        ?.notifier;
    _openPendingShortcut(session);
    _openPendingWidget(session);
    final sourceKey = (
      session,
      session?.selectedSchool?.id,
      session?.trustedScriptViewGeneration,
    );
    if (_sourceKey != sourceKey) {
      _sourceKey = sourceKey;
      final school = session?.selectedSchool?.id;
      _sources = () async {
        if (session == null || school == null) return <_ShellPage>[];
        try {
          final registry = await session.scriptRegistry;
          final pages = <_ShellPage>[];
          for (final installation in registry.installations) {
            final package = installation.package;
            if (!installation.enabled ||
                package.requiresUpdate ||
                package.manifest.schoolId != school) {
              continue;
            }
            for (final page in package.manifest.pages.where(
              (page) => page.tab,
            )) {
              pages.add(_ShellPage(package, page));
            }
          }
          final forum = registry.provider(school, 'forum.session');
          final messages =
              registry.provider(school, 'messages.conversations') ??
              registry.provider(school, 'messages.list');
          for (final (package, template) in [
            (forum, 'forum'),
            (messages, 'messages'),
          ]) {
            if (package != null &&
                !package.requiresUpdate &&
                !package.manifest.declaresPages) {
              pages.add(
                _ShellPage(
                  package,
                  ScriptPageEntry(
                    id: template,
                    title: template,
                    template: template,
                  ),
                  legacy: true,
                ),
              );
            }
          }
          return pages.take(3).toList(growable: false);
        } catch (_) {
          return <_ShellPage>[];
        }
      }();
    }
    return FutureBuilder<List<_ShellPage>>(
      key: ValueKey(sourceKey),
      future: _sources,
      builder: (context, snapshot) {
        final pages = snapshot.data ?? const <_ShellPage>[];
        final ids = ['home', for (final entry in pages) entry.id, 'settings'];
        // Stable tab identity survives insertion before Settings. An obsolete
        // community source is never kept alive using its previous index.
        if (!ids.contains(_tab) &&
            snapshot.connectionState == ConnectionState.done) {
          _tab = 'home';
        }
        final index = ids.contains(_tab) ? ids.indexOf(_tab) : 0;
        final tabs = _tabsOf(AppLocalizations.of(context), pages);
        void select(int i) => setState(() => _tab = ids[i]);
        final glassBar = buildLiquidGlassShellBar(
          context: context,
          tabs: tabs,
          selectedIndex: index,
          onSelected: select,
        );
        return Scaffold(
          extendBody: glassBar != null,
          body: IndexedStack(
            index: index,
            children: [
              TickerMode(
                enabled: _tab == 'home' && !_suspended,
                child: EleconHomePage(
                  key: ValueKey(
                    '${session?.selectedSchool?.id}:${session?.trustedScriptViewGeneration}',
                  ),
                  loadSnapshot: widget.loadHomeSnapshot,
                ),
              ),
              for (final entry in pages)
                _tab == entry.id && !_suspended
                    ? ScriptFeaturePage(
                        key: ValueKey((
                          entry.id,
                          sourceKey,
                          entry.package.digest,
                        )),
                        package: entry.package,
                        page: entry.page,
                      )
                    : const SizedBox.shrink(),
              const SettingsPage(key: ValueKey('settings')),
            ],
          ),
          bottomNavigationBar:
              glassBar ??
              _MaterialShellBar(
                tabs: tabs,
                selectedIndex: index,
                onSelected: select,
              ),
        );
      },
    );
  }
}

class _ShellPage {
  const _ShellPage(this.package, this.page, {this.legacy = false});
  final ScriptPackage package;
  final ScriptPageEntry page;
  final bool legacy;
  String get id =>
      legacy ? page.template : 'page:${package.manifest.id}/${page.id}';
}

/// Material 底栏：Stack + 满高超椭圆指示器（非仅图标后 32px 小条）。
class _MaterialShellBar extends StatelessWidget {
  const _MaterialShellBar({
    required this.tabs,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<LiquidGlassTabSpec> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  static const _height = 64.0;
  static const _padH = 12.0;
  static const _padV = 8.0;
  static const _inset = 4.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Material(
      color: Colors.transparent,
      child: Padding(
        padding: EdgeInsets.fromLTRB(_padH, 0, _padH, _padV + bottomInset),
        child: Material(
          elevation: 3,
          shadowColor: scheme.shadow.withValues(alpha: 0.2),
          surfaceTintColor: Colors.transparent,
          color: scheme.surfaceContainer,
          shape: AppTheme.barShape,
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            height: _height,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final n = tabs.length;
                final tabW = constraints.maxWidth / n;
                return Stack(
                  children: [
                    AnimatedPositionedDirectional(
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.easeOutCubic,
                      start: selectedIndex * tabW + _inset,
                      top: _inset,
                      bottom: _inset,
                      width: tabW - _inset * 2,
                      child: DecoratedBox(
                        decoration: ShapeDecoration(
                          color: scheme.secondaryContainer,
                          shape: const RoundedSuperellipseBorder(
                            borderRadius: BorderRadius.all(Radius.circular(20)),
                          ),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        for (var i = 0; i < n; i++)
                          Expanded(
                            child: _MaterialTab(
                              tab: tabs[i],
                              selected: i == selectedIndex,
                              onTap: () => onSelected(i),
                            ),
                          ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _MaterialTab extends StatelessWidget {
  const _MaterialTab({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final LiquidGlassTabSpec tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected
        ? scheme.onSecondaryContainer
        : scheme.onSurfaceVariant;
    final labelStyle = Theme.of(context).textTheme.labelMedium?.copyWith(
      color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
      fontSize: 12,
    );

    return Semantics(
      button: true,
      selected: selected,
      label: tab.label,
      child: InkWell(
        onTap: onTap,
        customBorder: const RoundedSuperellipseBorder(
          borderRadius: BorderRadius.all(Radius.circular(20)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              selected ? tab.selectedIcon : tab.icon,
              size: 24,
              color: color,
            ),
            const SizedBox(height: 2),
            Text(tab.label, style: labelStyle, maxLines: 1),
          ],
        ),
      ),
    );
  }
}
