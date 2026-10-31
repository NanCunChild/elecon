/// ADR-034 §2: all package sources require the same digest-bound consent.
library;

import 'package:flutter/material.dart';
import '../../core/scripts/manifest.dart';
import '../../l10n/gen/app_localizations.dart';

Future<bool> confirmScriptInstall(
  BuildContext context,
  List<ScriptPackage> packages,
) async {
  final l10n = AppLocalizations.of(context);
  return await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.scriptsTrustTitle),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final package in packages) ...[
                  Text(
                    '${package.manifest.name} · ${package.manifest.version}\n${package.manifest.id} · ${package.manifest.schoolId}',
                  ),
                  ExpansionTile(
                    title: Text(l10n.scriptsViewSource),
                    children: [SelectableText(package.source)],
                  ),
                  const SizedBox(height: 16),
                  Text(l10n.scriptsTrustBody),
                  if (package.manifest.actions.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(l10n.climatePermission),
                  ],
                  const SizedBox(height: 16),
                  Text(l10n.scriptsNetwork),
                  for (final origin in package.manifest.network.origins)
                    Text(origin.toString()),
                  const SizedBox(height: 12),
                  Text(l10n.scriptsIp),
                  Text(
                    package.manifest.network.ipAllow?.join('\n') ??
                        l10n.scriptsIpNone,
                  ),
                  if (package.manifest.browser) ...[
                    const SizedBox(height: 12),
                    Text(l10n.scriptsBrowserPermission),
                  ],
                  if (package.manifest.sdkVersion >= 3) ...[
                    const SizedBox(height: 12),
                    Text(l10n.scriptsInputPermission),
                  ],
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.scriptsApprove),
            ),
          ],
        ),
      ) ??
      false;
}
