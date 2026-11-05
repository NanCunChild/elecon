import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../session/profile_controller.dart';
import '../../session/profile_scope.dart';
import '../../session/session_controller.dart';

/// ADR-095: the current Profile remains closed until its original store opens.
class ProtectedStoreRecoveryPage extends StatefulWidget {
  const ProtectedStoreRecoveryPage({super.key, required this.session});
  final SessionController session;

  @override
  State<ProtectedStoreRecoveryPage> createState() =>
      _ProtectedStoreRecoveryPageState();
}

class _ProtectedStoreRecoveryPageState
    extends State<ProtectedStoreRecoveryPage> {
  bool _attemptFailed = false;
  bool _profileChangeFailed = false;

  Future<void> _retry() async {
    final profiles = ProfileScope.maybeOf(context);
    bool current() =>
        mounted &&
        (profiles == null ||
            (!profiles.busy &&
                identical(profiles.active.session, widget.session)));
    if (!current()) return;
    setState(() => _attemptFailed = false);
    final recovered = await widget.session.retryProtectedStore(
      isCurrent: current,
    );
    if (mounted && !recovered) setState(() => _attemptFailed = true);
  }

  Future<void> _switch(ProfileController profiles, String id) async {
    setState(() => _profileChangeFailed = false);
    try {
      await profiles.activate(id);
    } catch (_) {
      if (mounted) setState(() => _profileChangeFailed = true);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) {
      final l10n = AppLocalizations.of(context);
      final theme = Theme.of(context);
      final profiles = ProfileScope.maybeOf(context);
      final busy = widget.session.isRetryingProtectedStore;
      return PopScope(
        canPop: false,
        child: Scaffold(
          body: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(
                        Icons.lock_outline,
                        size: 48,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(height: 24),
                      if (profiles != null) ...[
                        Text(
                          profiles.active.name,
                          style: theme.textTheme.labelLarge,
                        ),
                        const SizedBox(height: 8),
                      ],
                      Text(
                        l10n.protectedStoreRecoveryTitle,
                        style: theme.textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 16),
                      Text(l10n.protectedStoreRecoveryBody),
                      if (_attemptFailed) ...[
                        const SizedBox(height: 16),
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            l10n.protectedStoreRecoveryFailed,
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      FilledButton(
                        key: const ValueKey('protected-store-retry'),
                        onPressed: busy || profiles?.busy == true
                            ? null
                            : _retry,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            busy
                                ? l10n.protectedStoreRecoveryRetrying
                                : l10n.commonRetry,
                          ),
                        ),
                      ),
                      if (profiles != null && profiles.profiles.length > 1) ...[
                        const SizedBox(height: 24),
                        for (final profile in profiles.profiles)
                          if (profile.id != profiles.active.id)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: OutlinedButton(
                                key: ValueKey(
                                  'protected-store-profile:${profile.id}',
                                ),
                                onPressed: profiles.busy
                                    ? null
                                    : () => _switch(profiles, profile.id),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                  child: Column(
                                    children: [
                                      Text(profile.name),
                                      Text(l10n.profilesActivate),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                        if (_profileChangeFailed)
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              l10n.profilesChangeFailed,
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
