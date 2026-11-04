import 'package:flutter/material.dart';
import '../../core/scripts/manifest.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../session/profile_controller.dart';
import '../../session/profile_scope.dart';
import '../../session/session_controller.dart';
import '../../session/session_scope.dart';

Future<void> changeProfile(
  BuildContext context,
  Future<void> Function() change,
) async {
  try {
    await change();
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).profilesChangeFailed),
        ),
      );
    }
  }
}

Future<void> showProfiles(BuildContext context) async {
  final profiles = ProfileScope.maybeOf(context);
  if (profiles == null) return;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: ListenableBuilder(
        listenable: profiles,
        builder: (_, _) => ListView(
          shrinkWrap: true,
          children: [
            for (final profile in profiles.profiles)
              ListTile(
                leading: Icon(
                  profile.id == profiles.active.id
                      ? Icons.account_circle
                      : Icons.account_circle_outlined,
                ),
                title: _ProfileName(
                  name: profile.name,
                  active: profile.id == profiles.active.id,
                ),
                subtitle: Text(
                  !profile.session.isRestored &&
                          profile.id != profiles.active.id
                      ? AppLocalizations.of(context).profilesNotLoaded
                      : profile.session.selectedSchool?.displayName ??
                            AppLocalizations.of(context).settingsNoSchool,
                ),
                enabled: !profiles.busy,
                onTap: () {
                  Navigator.pop(sheetContext);
                  changeProfile(context, () => profiles.activate(profile.id));
                },
              ),
          ],
        ),
      ),
    ),
  );
}

class ProfileAccountsHeader extends StatelessWidget {
  const ProfileAccountsHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final profiles = ProfileScope.maybeOf(context);
    final l10n = AppLocalizations.of(context);
    return Row(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              l10n.settingsSectionAccount,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        ),
        if (profiles != null)
          IconButton(
            key: const ValueKey('profile-add'),
            tooltip: l10n.profilesAdd,
            icon: const Icon(Icons.add),
            onPressed: profiles.busy
                ? null
                : () => changeProfile(context, profiles.add),
          ),
      ],
    );
  }
}

class _ProfileName extends StatelessWidget {
  const _ProfileName({required this.name, required this.active});
  final String name;
  final bool active;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 4,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Text(name),
      if (active)
        Text(
          AppLocalizations.of(context).profilesCurrent,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
    ],
  );
}

class ProfileAccounts extends StatelessWidget {
  const ProfileAccounts({
    super.key,
    required this.onLogin,
    required this.onLogout,
    required this.onSelectScript,
  });
  final VoidCallback onLogin, onLogout, onSelectScript;

  void _details(BuildContext context, SessionProfile? profile) {
    final profiles = ProfileScope.maybeOf(context);
    final session = profile?.session ?? SessionScope.of(context);
    final l10n = AppLocalizations.of(context);
    final current = profile == null || profile.id == profiles?.active.id;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: _ProfileName(
                name: profile?.name ?? 'Profile 1',
                active: current,
              ),
              subtitle: Text(
                !current && !session.isRestored
                    ? l10n.profilesNotLoaded
                    : session.selectedSchool?.displayName ??
                          l10n.settingsNoSchool,
              ),
            ),
            if (!current)
              ListTile(
                leading: const Icon(Icons.switch_account),
                title: Text(l10n.profilesActivate),
                onTap: () {
                  Navigator.pop(sheetContext);
                  changeProfile(context, () => profiles!.activate(profile.id));
                },
              ),
            if (current) ...[
              ListTile(
                leading: const Icon(Icons.login),
                title: Text(
                  session.isLoggedIn
                      ? l10n.settingsRelogin
                      : l10n.settingsActionLogin,
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  onLogin();
                },
              ),
              if (session.isLoggedIn)
                ListTile(
                  leading: const Icon(Icons.logout),
                  title: Text(l10n.settingsActionLogout),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    onLogout();
                  },
                ),
              ListTile(
                leading: const Icon(Icons.code),
                title: Text(l10n.profilesSelectScript),
                onTap: () {
                  Navigator.pop(sheetContext);
                  onSelectScript();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profiles = ProfileScope.maybeOf(context);
    final current = SessionScope.of(context);
    return Column(
      children: [
        if (profiles == null)
          _ProfileRow(
            name: 'Profile 1',
            session: current,
            active: true,
            onTap: () => _details(context, null),
          )
        else
          for (final profile in profiles.profiles)
            _ProfileRow(
              key: ValueKey('profile:${profile.id}'),
              name: profile.name,
              session: profile.session,
              active: profile.id == profiles.active.id,
              onTap: profiles.busy ? null : () => _details(context, profile),
            ),
      ],
    );
  }
}

class _ProfileRow extends StatelessWidget {
  const _ProfileRow({
    super.key,
    required this.name,
    required this.session,
    required this.active,
    this.onTap,
  });
  final String name;
  final SessionController session;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (!active && !session.isRestored) {
      return ListTile(
        leading: const Icon(Icons.account_circle_outlined),
        title: _ProfileName(name: name, active: active),
        subtitle: Text(l10n.profilesNotLoaded),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      );
    }
    final protection = session.credentialProtection;
    final (icon, label) = switch (protection) {
      SessionCredentialProtection.hardware => (
        Icons.verified_user_outlined,
        l10n.settingsProtectionHardware,
      ),
      SessionCredentialProtection.software => (
        Icons.lock_outline,
        l10n.settingsProtectionSoftware,
      ),
      SessionCredentialProtection.mixed => (
        Icons.security_outlined,
        l10n.settingsProtectionMixed,
      ),
      _ => (Icons.lock_open_outlined, l10n.settingsProtectionMemory),
    };
    return FutureBuilder<ScriptPackage?>(
      future: session.scriptRegistry.then(
        (r) => r.provider(session.selectedSchool?.id ?? '', 'generic.section'),
      ),
      builder: (_, snapshot) {
        final script =
            snapshot.data?.manifest.name ??
            session.selectedSchool?.displayName ??
            l10n.settingsNoSchool;
        return ListTile(
          leading: Icon(
            active ? Icons.account_circle : Icons.account_circle_outlined,
          ),
          title: _ProfileName(name: name, active: active),
          subtitle: Text(
            '$script · ${session.isLoggedIn ? l10n.settingsLoggedIn : l10n.settingsLoggedOut}',
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (session.isLoggedIn)
                Tooltip(
                  message: label,
                  child: Icon(icon, semanticLabel: label, size: 20),
                ),
              const Icon(Icons.chevron_right),
            ],
          ),
          onTap: onTap,
        );
      },
    );
  }
}
