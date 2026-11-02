/// ADR-043: finite host-owned previews; the complete snapshot stays reachable.
library;

import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import '../../session/session_scope.dart';
import 'card_layout.dart';

class CardPreviewList extends StatelessWidget {
  const CardPreviewList({
    super.key,
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final session = context
        .dependOnInheritedWidgetOfExactType<SessionScope>()
        ?.notifier;
    final generation = session?.trustedScriptViewGeneration;
    final presentation = HomeCardPresentation.maybeOf(context);
    final limit = presentation?.isPage == true
        ? children.length
        : switch (HomeCardPresentation.of(context)) {
            HomeCardSize.compact => 1,
            HomeCardSize.regular => 3,
            HomeCardSize.expanded => 10,
          };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...children.take(limit),
        if (children.length > limit && presentation?.onOpen == null)
          TextButton.icon(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (context) => _PreviewSnapshotPage(
                  title: title,
                  session: session,
                  generation: generation,
                  children: children,
                ),
              ),
            ),
            icon: const Icon(Icons.open_in_full),
            label: Text(
              AppLocalizations.of(context).homeCardShowAll(children.length),
            ),
          ),
      ],
    );
  }
}

// A private snapshot must disappear after logout, source changes or school switch.
class _PreviewSnapshotPage extends StatelessWidget {
  const _PreviewSnapshotPage({
    required this.title,
    required this.children,
    required this.session,
    required this.generation,
  });
  final String title;
  final List<Widget> children;
  final SessionController? session;
  final int? generation;

  @override
  Widget build(BuildContext context) {
    final current = context
        .dependOnInheritedWidgetOfExactType<SessionScope>()
        ?.notifier;
    Widget body() {
      if (session != null &&
          (!identical(current, session) ||
              generation != session!.trustedScriptViewGeneration)) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Text(AppLocalizations.of(context).homeCardDataChanged),
        );
      }
      return HomeCardPresentation(
        size: HomeCardSize.expanded,
        child: ListView(padding: const EdgeInsets.all(16), children: children),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: session == null || !identical(current, session)
          ? body()
          : ListenableBuilder(listenable: session!, builder: (_, _) => body()),
    );
  }
}
