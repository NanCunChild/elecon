import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import '../../session/session_scope.dart';
import 'card_layout.dart';

/// Bind the opened feature to the identity and source the user actually chose.
/// The board lends its mounted content to this route, retaining query state.
class HomeFeaturePage extends StatelessWidget {
  const HomeFeaturePage({
    super.key,
    required this.card,
    required this.contentKey,
    required this.active,
    required this.onClosed,
    this.preset = HomeCardPreset.standard,
    this.session,
    this.generation,
    this.dataGeneration,
  });
  final HomeCardEntry card;
  final GlobalKey contentKey;
  final ValueNotifier<bool> active;
  final VoidCallback onClosed;
  final String preset;
  final SessionController? session;
  final int? generation;
  final int? dataGeneration;

  @override
  Widget build(BuildContext context) {
    final current = context
        .dependOnInheritedWidgetOfExactType<SessionScope>()
        ?.notifier;
    Widget body() =>
        session != null &&
            (!identical(session, current) ||
                generation != session!.trustedScriptViewGeneration ||
                (dataGeneration != null &&
                    dataGeneration != session!.trustedScriptDataGeneration))
        ? Center(child: Text(AppLocalizations.of(context).homeCardDataChanged))
        : HomeCardPresentation(
            size: HomeCardSize.expanded,
            isPage: true,
            pageTitle: card.label,
            preset: preset,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: KeyedSubtree(
                key: contentKey,
                child: Builder(builder: card.builder),
              ),
            ),
          );
    return PopScope<Object?>(
      onPopInvokedWithResult: (popped, _) {
        if (popped) {
          active.value = false;
          onClosed();
        }
      },
      child:
          card.pageBuilder != null &&
              (session == null ||
                  (identical(session, current) &&
                      generation == session!.trustedScriptViewGeneration &&
                      (dataGeneration == null ||
                          dataGeneration ==
                              session!.trustedScriptDataGeneration)))
          ? Builder(builder: card.pageBuilder!)
          : Scaffold(
              appBar: AppBar(title: Text(card.label)),
              body: SafeArea(
                child: ValueListenableBuilder<bool>(
                  valueListenable: active,
                  builder: (_, visible, _) => !visible
                      ? const SizedBox.shrink()
                      : session == null
                      ? body()
                      : ListenableBuilder(
                          listenable: session!,
                          builder: (_, _) => body(),
                        ),
                ),
              ),
            ),
    );
  }
}
