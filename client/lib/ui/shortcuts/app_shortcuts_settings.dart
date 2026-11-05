import 'package:flutter/material.dart';
import '../../core/navigation/app_feature.dart';
import '../../core/navigation/app_shortcuts_controller.dart';
import '../../l10n/gen/app_localizations.dart';
import '../home/native_feature.dart';
import 'app_shortcuts_scope.dart';

class AppShortcutsSettingsTile extends StatelessWidget {
  const AppShortcutsSettingsTile({super.key});

  @override
  Widget build(BuildContext context) {
    final shortcuts = AppShortcutsScope.maybeOf(context);
    if (shortcuts?.channel == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    return ListTile(
      leading: const Icon(Icons.shortcut_outlined),
      title: Text(l10n.shortcutsTitle),
      subtitle: Text(l10n.shortcutsHint),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => AppShortcutsSettingsPage(controller: shortcuts!),
        ),
      ),
    );
  }
}

class AppShortcutsSettingsPage extends StatefulWidget {
  const AppShortcutsSettingsPage({super.key, required this.controller});
  final AppShortcutsController controller;

  @override
  State<AppShortcutsSettingsPage> createState() =>
      _AppShortcutsSettingsPageState();
}

class _AppShortcutsSettingsPageState extends State<AppShortcutsSettingsPage> {
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    widget.controller.refreshPinState();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  String _message(ShortcutPinResult result, AppLocalizations l10n) =>
      switch (result) {
        ShortcutPinResult.requested => l10n.shortcutsPending,
        ShortcutPinResult.pinned => l10n.shortcutsPinned,
        ShortcutPinResult.unsupported => l10n.shortcutsUnsupported,
        ShortcutPinResult.restricted => l10n.shortcutsRestricted,
        ShortcutPinResult.unavailable => l10n.shortcutsTemporarilyUnavailable,
        ShortcutPinResult.failed => l10n.shortcutsPinFailed,
      };

  Future<void> _pin(AppFeature feature) async {
    setState(() => _busy = true);
    final result = await widget.controller.requestPin(feature);
    if (!mounted) return;
    setState(() => _busy = false);
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(_message(result, l10n))));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.shortcutsTitle)),
      body: SafeArea(
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(l10n.shortcutsHint),
            ),
            if (!widget.controller.supported)
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: Text(
                  _message(
                    widget.controller.availabilityFailure ??
                        ShortcutPinResult.unsupported,
                    l10n,
                  ),
                ),
                trailing: IconButton(
                  tooltip: MaterialLocalizations.of(
                    context,
                  ).refreshIndicatorSemanticLabel,
                  icon: const Icon(Icons.refresh),
                  onPressed: widget.controller.refreshPinState,
                ),
              ),
            for (final feature in AppFeature.values)
              ListTile(
                title: Text(nativeFeatureTitle(feature, l10n)),
                subtitle: widget.controller.pinResult(feature) == null
                    ? null
                    : Text(
                        _message(widget.controller.pinResult(feature)!, l10n),
                      ),
                trailing: Icon(
                  widget.controller.pinned.contains(feature)
                      ? Icons.check_circle_outline
                      : Icons.add_to_home_screen_outlined,
                ),
                onTap: _busy ? null : () => _pin(feature),
              ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.widgets_outlined),
              title: Text(l10n.scheduleWidgetTitle),
              subtitle: Text(l10n.scheduleWidgetHint),
            ),
          ],
        ),
      ),
    );
  }
}
