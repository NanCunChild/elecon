import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/ai/app_functions_controller.dart';
import '../../l10n/gen/app_localizations.dart';
import 'app_functions_scope.dart';

class AppFunctionsSettingsTile extends StatelessWidget {
  const AppFunctionsSettingsTile({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = AppFunctionsScope.maybeOf(context);
    if (controller == null || defaultTargetPlatform != TargetPlatform.android) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    return ListTile(
      leading: const Icon(Icons.assistant_outlined),
      title: Text(l10n.aiAccessTitle),
      subtitle: Text(l10n.aiAccessSummary),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => AppFunctionsSettingsPage(controller: controller),
        ),
      ),
    );
  }
}

class AppFunctionsSettingsPage extends StatefulWidget {
  const AppFunctionsSettingsPage({super.key, required this.controller});
  final AppFunctionsController controller;

  @override
  State<AppFunctionsSettingsPage> createState() =>
      _AppFunctionsSettingsPageState();
}

class _AppFunctionsSettingsPageState extends State<AppFunctionsSettingsPage> {
  late final Future<bool> _supported = widget.controller.isPlatformSupported();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.aiAccessTitle)),
      body: FutureBuilder<bool>(
        future: _supported,
        builder: (context, platform) => ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) => FutureBuilder<List<AiServiceChoice>>(
            future: widget.controller.choices(),
            builder: (context, snapshot) => ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(l10n.aiAccessExplanation),
                ),
                if (platform.data != true)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(l10n.aiAccessUnsupported),
                  ),
                for (final choice in snapshot.data ?? <AiServiceChoice>[])
                  SwitchListTile(
                    key: ValueKey('ai-access-${choice.query.name}'),
                    title: Text(switch (choice.query) {
                      AiQuery.schedule => l10n.aiAccessSchedule,
                      AiQuery.classrooms => l10n.aiAccessClassrooms,
                      AiQuery.grades => l10n.aiAccessGrades,
                    }),
                    subtitle: choice.available
                        ? null
                        : Text(l10n.aiAccessUnavailable),
                    value: choice.authorized,
                    onChanged: choice.available && platform.data == true
                        ? (value) =>
                              widget.controller.setAllowed(choice.query, value)
                        : null,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
