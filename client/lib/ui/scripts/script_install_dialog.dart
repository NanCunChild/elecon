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
                  if (package.manifest.homeTitle != null)
                    Text(l10n.scriptsHomeTitle(package.manifest.homeTitle!)),
                  ExpansionTile(
                    title: Text(l10n.scriptsViewSource),
                    children: [SelectableText(package.source)],
                  ),
                  const SizedBox(height: 16),
                  Text(l10n.scriptsTrustBody),
                  const SizedBox(height: 16),
                  Text(l10n.scriptsNetwork),
                  for (final origin in package.manifest.network.origins)
                    Text(origin.toString()),
                  if (package.manifest.websocketNetwork.origins.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(l10n.scriptsWebsocketPermission),
                    for (final origin
                        in package.manifest.websocketNetwork.origins)
                      Text(origin.replace(scheme: 'wss').toString()),
                  ],
                  const SizedBox(height: 12),
                  Text(l10n.scriptsIp),
                  Text(
                    package.manifest.network.ipAllow?.join('\n') ??
                        l10n.scriptsIpNone,
                  ),
                  if (package.manifest.scanner) ...[
                    const SizedBox(height: 12),
                    Text(l10n.scannerPermission),
                  ],
                  for (final input in package.manifest.deviceInputs) ...[
                    const SizedBox(height: 12),
                    Text(switch (input) {
                      'camera' => l10n.deviceInputCameraPermission,
                      'image' => l10n.deviceInputImagePermission,
                      _ => l10n.deviceInputLocationPermission,
                    }),
                  ],
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
