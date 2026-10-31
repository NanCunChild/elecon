/// ADR-034 §2: bundled source is an import convenience, never execution consent.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/scripts/manifest.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import 'script_install_dialog.dart';

class BundledScriptSchool {
  const BundledScriptSchool(this.id, this.dataId, this.loginId);
  final String id;
  final String dataId;
  final String loginId;

  String label(AppLocalizations l10n) => switch (id) {
    'xidian_undergraduate' => l10n.scriptsXidianUndergraduate,
    'xidian_postgraduate' => l10n.scriptsXidianPostgraduate,
    _ => id,
  };

  Future<List<ScriptPackage>> load() async {
    final packages = <ScriptPackage>[];
    for (final packageId in [dataId]) {
      final package = ScriptPackage.parse(
        await rootBundle.loadString(
          'assets/school-scripts/$packageId.elecon.json',
        ),
      );
      if (package.manifest.id != packageId || package.manifest.schoolId != id) {
        throw StateError('bundled_script_identity_mismatch');
      }
      packages.add(package);
    }
    return packages;
  }
}

// ADR-034 migration: show current source identities in the default school list.
const bundledLegacySchoolIds = {'xidian'};

const bundledScriptSchools = [
  BundledScriptSchool(
    'xidian_undergraduate',
    'school-xidian-undergraduate',
    'school-xidian-undergraduate-login',
  ),
  BundledScriptSchool(
    'xidian_postgraduate',
    'school-xidian-postgraduate',
    'school-xidian-postgraduate-login',
  ),
];

Future<bool> installBundledSchool(
  BuildContext context,
  SessionController session,
  BundledScriptSchool school,
) async {
  final bundled = await school.load();
  final registry = await session.scriptRegistry;
  // Keep explicitly installed newer versions. Still show their actual contents
  // when selecting/re-enabling this school; never silently downgrade an update.
  final packages = [
    for (final package in bundled)
      if (registry.find(package.manifest.id) case final installed?
          when compareScriptVersions(
                installed.package.manifest.version,
                package.manifest.version,
              ) >
              0)
        installed.package
      else
        package,
  ];
  if (!context.mounted || !await confirmScriptInstall(context, packages)) {
    return false;
  }
  for (final package in packages) {
    await session.installTrustedScript(package, approvedDigest: package.digest);
    // Selecting a bundled school is an explicit re-enable operation; ordinary
    // package updates retain the user's disabled state.
    await session.enableTrustedScript(package.manifest.id, true);
  }
  // ADR-034 §2 / ADR-035 §2: retire the standalone install only after the
  // unified provider is approved. Uninstall retains same-school credentials.
  if (packages.any(
        (p) =>
            p.manifest.browser &&
            p.manifest.capabilities.any((c) => c.id == 'generic.section'),
      ) &&
      registry.find(school.loginId) != null) {
    final previous = registry.provider(school.id, 'generic.section');
    if (previous == null || previous.manifest.id == school.loginId) {
      // This is the explicit standalone-login → unified-package migration,
      // not a general fallback to whichever package was installed last.
      await session.selectTrustedScriptProvider(
        school.id,
        'generic.section',
        school.dataId,
      );
    }
    await session.removeTrustedScript(school.loginId);
  }
  await session.selectTrustedScriptSchool(school.dataId);
  return true;
}
