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
    if (shortcuts?.supported != true) return const SizedBox.shrink();
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
  Future<void> _pin(AppFeature feature) async {
    setState(() => _busy = true);
    final accepted = await widget.controller.pin(feature);
    if (!mounted) return;
    setState(() => _busy = false);
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          accepted ? l10n.shortcutsRequested : l10n.shortcutsPinFailed,
        ),
      ),
    );
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
            for (final feature in AppFeature.values)
              ListTile(
                title: Text(nativeFeatureTitle(feature, l10n)),
                trailing: const Icon(Icons.add_to_home_screen_outlined),
                onTap: _busy ? null : () => _pin(feature),
              ),
          ],
        ),
      ),
    );
  }
}
