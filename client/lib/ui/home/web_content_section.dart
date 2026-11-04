/// Fixed launcher/result template for explicitly opened package web content.
library;

import 'package:flutter/material.dart';
import '../../core/scripts/manifest.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import 'card_layout.dart';
import 'foreground_request_section.dart';
import 'section_card.dart';

class WebContentSection extends StatelessWidget {
  const WebContentSection({
    super.key,
    required this.session,
    required this.package,
    required this.page,
  });
  final SessionController session;
  final ScriptPackage package;
  final ScriptWebContent page;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (HomeCardPresentation.maybeOf(context)?.isPage != true) {
      return SectionCard(
        title: page.title,
        subtitle: package.manifest.name,
        child: Text(l10n.webContentOpen),
      );
    }
    return ForegroundRequestSection(
      session: session,
      package: package,
      title: page.title,
      actions: [
        ForegroundRequestAction(
          capability: 'web.content',
          label: l10n.webContentOpen,
          icon: Icons.web_outlined,
          params: () => {'pageId': page.id},
        ),
      ],
      resultBuilder: (context, _, result) {
        if (!result.ok) {
          return Text(switch (result.reason) {
            'browser_content_unavailable' ||
            'browser_unavailable' => l10n.webContentUnavailable,
            'authentication_required' => l10n.communityLoginRequired,
            // A cancelled host call might have interrupted a submitted request.
            // Only the script can attest that no submission occurred.
            _ => l10n.webContentUnknown,
          });
        }
        final data = result.data;
        if (data is! Map || data['pageId'] != page.id) {
          return Text(l10n.webContentUnknown);
        }
        return Text(switch (data['status']) {
          'completed' => l10n.webContentCompleted,
          'cancelled' => l10n.webContentCancelled,
          _ => l10n.webContentUnknown,
        });
      },
    );
  }
}
