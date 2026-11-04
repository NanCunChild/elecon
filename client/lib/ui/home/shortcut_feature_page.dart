import 'package:flutter/material.dart';

import '../../core/navigation/app_feature.dart';
import '../../core/scripts/manifest.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import '../../session/session_scope.dart';
import 'capability_source.dart';
import 'card_layout.dart';
import 'native_feature.dart';

/// A system shortcut opens the existing native component with its provider fixed
/// for this page. It does not depend on card visibility or modify home layout.
class ShortcutFeaturePage extends StatefulWidget {
  const ShortcutFeaturePage({super.key, required this.feature});
  final AppFeature feature;

  @override
  State<ShortcutFeaturePage> createState() => _ShortcutFeaturePageState();
}

class _ShortcutFeaturePageState extends State<ShortcutFeaturePage> {
  SessionController? _session;
  int? _generation;
  int? _dataGeneration;
  Future<ScriptPackage?>? _provider;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_session != null) return;
    final session = SessionScope.of(context);
    _session = session;
    _generation = session.trustedScriptViewGeneration;
    _dataGeneration = session.trustedScriptDataGeneration;
    final school = session.selectedSchool?.id;
    _provider = () async {
      if (!session.isRestored ||
          session.hardwareUnlockFailed ||
          school == null) {
        return null;
      }
      return nativeFeatureProvider(
        await session.scriptRegistry,
        school,
        widget.feature,
      );
    }();
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final l10n = AppLocalizations.of(context);
    final title = nativeFeatureTitle(widget.feature, l10n);
    final current =
        identical(session, _session) &&
        session.trustedScriptViewGeneration == _generation &&
        session.trustedScriptDataGeneration == _dataGeneration;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: !current
            ? Center(child: Text(l10n.homeCardDataChanged))
            : FutureBuilder<ScriptPackage?>(
                future: _provider,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final package = snapshot.data;
                  if (package == null) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(l10n.shortcutsUnavailable),
                      ),
                    );
                  }
                  return HomeCardPresentation(
                    size: HomeCardSize.expanded,
                    isPage: true,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: CapabilitySourceScope(
                        source: CapabilitySource(
                          packageId: package.manifest.id,
                          digest: package.digest,
                        ),
                        title: title,
                        child: nativeFeatureContent(widget.feature, package),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
