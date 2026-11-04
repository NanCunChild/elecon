/// ADR-034 §2: all package sources require the same digest-bound consent.
library;

import 'dart:convert';
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
                  if (package.manifest.school case final school?)
                    Text('${school.name} · ${school.type.name}'),
                  ExpansionTile(
                    title: Text(l10n.scriptsViewSource),
                    children: [SelectableText(package.source)],
                  ),
                  for (final page in package.manifest.webContent)
                    ExpansionTile(
                      key: ValueKey(
                        'web-content-source-${package.manifest.id}-${page.id}',
                      ),
                      title: Text('${page.title} · ${page.id}'),
                      subtitle: Text(l10n.scriptsViewSource),
                      children: [SelectableText(page.html)],
                    ),
                  if (package.manifest.localization
                      case final localization?) ...[
                    Text(
                      l10n.scriptsLanguages(
                        localization.supportedLocales.join(', '),
                      ),
                    ),
                    Text(
                      l10n.scriptsDefaultLanguage(localization.defaultLocale),
                    ),
                    ExpansionTile(
                      title: Text(l10n.scriptsViewTranslations),
                      children: [
                        SelectableText(
                          const JsonEncoder.withIndent(
                            '  ',
                          ).convert(localization.messages),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),
                  Text(l10n.scriptsTrustBody),
                  if (package.manifest.declaresAccounts) ...[
                    const SizedBox(height: 12),
                    Text(l10n.scriptAccountsTitle),
                    if (package.manifest.accounts.isEmpty)
                      Text(l10n.scriptAccountsNone),
                    for (final account in package.manifest.accounts) ...[
                      const SizedBox(height: 12),
                      Text(
                        account.name,
                        style: Theme.of(ctx).textTheme.titleSmall,
                      ),
                      Text(account.instructions),
                      if (account.appTunnelAccountId case final dependency?)
                        Text(
                          l10n.scriptTunnelDependency(
                            package.manifest.accounts
                                .firstWhere((target) => target.id == dependency)
                                .name,
                          ),
                        ),
                      if (account.appTunnel case final tunnel?) ...[
                        Text(tunnel.gatewayUrl),
                        ExpansionTile(
                          key: ValueKey('tunnel-review-${account.id}'),
                          title: Text(l10n.appTunnelTitle),
                          subtitle: Text(l10n.scriptTunnelManagedDescription),
                          children: [
                            ListTile(
                              title: Text(l10n.appTunnelDomain),
                              subtitle: Text(
                                tunnel.loginDomain.isEmpty
                                    ? l10n.scriptTunnelDefaultDomain
                                    : tunnel.loginDomain,
                              ),
                            ),
                            ListTile(
                              title: Text(l10n.appTunnelCertificate),
                              subtitle: SelectableText(
                                tunnel.nodeCertificateSha256 ??
                                    l10n.scriptTunnelSystemCertificate,
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (account.credentialReuse case final reuse?)
                        Text(
                          l10n.scriptAccountCredentialReuse(
                            package.manifest.accounts
                                .firstWhere(
                                  (source) =>
                                      source.id == reuse.sourceAccountId,
                                )
                                .name,
                            reuse.gatewayUrl,
                          ),
                        ),
                    ],
                  ],
                  for (final capability in package.manifest.capabilities)
                    if (capability.appTunnelAccountId case final dependency?)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          '${capability.id} · ${l10n.scriptTunnelDependency(package.manifest.accounts.firstWhere((target) => target.id == dependency).name)}',
                        ),
                      ),
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
                  if (package.manifest.appTunnels.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(l10n.scriptsAppTunnelPermission),
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
