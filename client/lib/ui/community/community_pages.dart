import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';

/// ADR-051: local navigation reservations; no service or account is connected.
class ForumPage extends StatelessWidget {
  const ForumPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _PlannedCommunityPage(
      title: l10n.navForum,
      heading: l10n.forumPlannedTitle,
      description: l10n.forumPlannedDescription,
      accountDescription: l10n.forumPlannedAccount,
      icon: Icons.forum_outlined,
    );
  }
}

class MessagesPage extends StatelessWidget {
  const MessagesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _PlannedCommunityPage(
      title: l10n.navMessages,
      heading: l10n.messagesPlannedTitle,
      description: l10n.messagesPlannedDescription,
      accountDescription: l10n.messagesPlannedAccount,
      icon: Icons.chat_bubble_outline,
    );
  }
}

class _PlannedCommunityPage extends StatelessWidget {
  const _PlannedCommunityPage({
    required this.title,
    required this.heading,
    required this.description,
    required this.accountDescription,
    required this.icon,
  });

  final String title;
  final String heading;
  final String description;
  final String accountDescription;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 100),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Icon(
                      icon,
                      size: 48,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(heading, style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 12),
                  Text(description, style: theme.textTheme.bodyLarge),
                  const SizedBox(height: 24),
                  Card.filled(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            l10n.communityPlannedAccountTitle,
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(accountDescription),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l10n.communityPlannedAvailability,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
