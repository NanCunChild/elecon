import 'package:flutter/material.dart';

import '../../core/navigation/app_feature.dart';
import '../../core/scripts/manifest.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import '../../session/session_scope.dart';
import '../community/community_pages.dart';
import 'capability_source.dart';
import 'card_layout.dart';
import 'generic_section.dart';
import 'native_feature.dart';
import 'web_content_section.dart';

/// One approved package owns both the portal and its detail page (ADR-086).
class ScriptFeaturePage extends StatefulWidget {
  const ScriptFeaturePage({
    super.key,
    required this.package,
    required this.page,
  });
  final ScriptPackage package;
  final ScriptPageEntry page;

  @override
  State<ScriptFeaturePage> createState() => _ScriptFeaturePageState();
}

class _ScriptFeaturePageState extends State<ScriptFeaturePage> {
  SessionController? _session;
  int? _identity;
  int? _sourceRevision;
  int? _dataGeneration;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_session != null) return;
    _session = SessionScope.of(context);
    _identity = _session!.identityRevision;
    _sourceRevision = _session!.trustedScriptSourceRevision;
    _dataGeneration = _session!.trustedScriptDataGeneration;
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final page = widget.page;
    final package = widget.package;
    if (!identical(session, _session) ||
        session.identityRevision != _identity ||
        session.trustedScriptSourceRevision != _sourceRevision ||
        session.trustedScriptDataGeneration != _dataGeneration ||
        session.selectedSchool?.id != package.manifest.schoolId) {
      return Scaffold(
        appBar: AppBar(title: Text(page.title)),
        body: Center(
          child: Text(AppLocalizations.of(context).homeCardDataChanged),
        ),
      );
    }
    if (page.template == 'forum') {
      return ForumPage(session: session, package: package);
    }
    if (page.template == 'messages') {
      return MessagesPage(session: session, package: package);
    }
    final content = switch (page.template) {
      'web' => WebContentSection(
        session: session,
        package: package,
        page: package.manifest.webContent.singleWhere(
          (web) => web.id == page.webPageId,
        ),
      ),
      'generic' => const GenericCapabilitySection(),
      _ => nativeFeatureContent(AppFeature.fromId(page.template)!, package),
    };
    return Scaffold(
      appBar: AppBar(title: Text(page.title)),
      body: SafeArea(
        child: HomeCardPresentation(
          size: HomeCardSize.expanded,
          isPage: true,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: CapabilitySourceScope(
              source: CapabilitySource(
                packageId: package.manifest.id,
                digest: package.digest,
              ),
              title: page.title,
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}

IconData scriptPageIcon(String template) => switch (template) {
  'forum' => Icons.forum_outlined,
  'messages' => Icons.chat_bubble_outline,
  'web' => Icons.web_outlined,
  'schedule' => Icons.calendar_month_outlined,
  'grades' => Icons.school_outlined,
  'card' => Icons.account_balance_wallet_outlined,
  'library' => Icons.menu_book_outlined,
  'classroom' => Icons.meeting_room_outlined,
  'directory' => Icons.contact_phone_outlined,
  _ => Icons.widgets_outlined,
};
