import 'package:flutter/material.dart';

import '../../core/adapter_service.dart';
import '../../core/scripts/manifest.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import '../../session/session_scope.dart';
import '../community/checkin_locations.dart';
import '../settings/dev_log_page.dart';
import 'card_layout.dart';
import 'foreground_request_section.dart';
import 'section_card.dart';

/// Standard attendance data binding. Authentication and scanning remain script
/// work; the host does not inspect QR payloads or implement a service protocol.
class CheckinSection extends StatefulWidget {
  const CheckinSection({super.key});
  @override
  State<CheckinSection> createState() => _CheckinSectionState();
}

class _CheckinSectionState extends State<CheckinSection> {
  SessionController? _session;
  int? _generation;
  Future<ScriptPackage?>? _provider;
  AttendancePlace? _place;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = SessionScope.of(context);
    if (_session != session ||
        _generation != session.trustedScriptViewGeneration) {
      _session = session;
      _generation = session.trustedScriptViewGeneration;
      _place = null;
      final school = session.selectedSchool?.id;
      _provider = () async {
        if (school == null) return null;
        try {
          return (await session.scriptRegistry).provider(
            school,
            'attendance.checkin',
          );
        } catch (_) {
          return null;
        }
      }();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Even an expanded home card is a launcher. Only the opened feature page
    // owns ephemeral location selection, account interaction and results.
    if (HomeCardPresentation.maybeOf(context)?.isPage != true) {
      return SectionCard(
        title: l10n.homeCheckinTitle,
        summary: Text(l10n.checkinInputHelp),
        child: Text(l10n.checkinInputHelp),
      );
    }
    return FutureBuilder<ScriptPackage?>(
      key: ValueKey((_session, _generation)),
      future: _provider,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const LinearProgressIndicator();
        }
        final package = snapshot.data;
        if (package == null) return Text(l10n.homeCardDataChanged);
        return ForegroundRequestSection(
          key: ValueKey((_generation, package.digest)),
          session: _session!,
          package: package,
          title: l10n.homeCheckinTitle,
          onReset: () => _place = null,
          footerBuilder: (context, enabled) => Align(
            alignment: AlignmentDirectional.centerEnd,
            child: IconButton(
              tooltip: l10n.devLogTitle,
              icon: const Icon(Icons.bug_report_outlined),
              onPressed: enabled
                  ? () => Navigator.of(context).push<void>(
                      MaterialPageRoute(builder: (_) => const DevLogPage()),
                    )
                  : null,
            ),
          ),
          inputsBuilder:
              package.manifest
                      .capability('attendance.checkin')
                      ?.schemaVersion ==
                  '1.1'
              ? (context, enabled) => CheckinLocations(
                  session: _session!,
                  package: package,
                  enabled: enabled,
                  onSelected: (place) => _place = place,
                )
              : null,
          actions: [
            if (package.manifest.capability('messages.session') != null)
              ForegroundRequestAction(
                capability: 'messages.session',
                label: l10n.communityConnect,
                icon: Icons.login,
                params: () => {'operation': 'login'},
              ),
            ForegroundRequestAction(
              capability: 'attendance.checkin',
              label: l10n.checkinStart,
              icon: Icons.how_to_reg_outlined,
              params: () =>
                  _place == null ? {} : {'location': _place!.location},
            ),
          ],
          resultBuilder: (context, capability, result) =>
              Text(_resultText(l10n, package, capability, result)),
        );
      },
    );
  }
}

String _resultText(
  AppLocalizations l10n,
  ScriptPackage package,
  String capability,
  CapabilityRun result,
) {
  if (!result.ok) {
    return switch (result.reason) {
      'authentication_required' => l10n.communityLoginRequired,
      'input_cancelled' ||
      'script_cancelled' ||
      'invocation_cancelled' => l10n.checkinCancelled,
      'input_invalid_request' when capability == 'attendance.checkin' =>
        l10n.checkinQrInvalid,
      _ =>
        capability == 'attendance.checkin'
            ? l10n.checkinUnknown
            : l10n.communityRequestFailed,
    };
  }
  final data = Map<String, dynamic>.from(result.data as Map);
  if (capability == 'messages.session') {
    return data['status'] == 'authenticated'
        ? l10n.communityConnected(
            data['serviceName'] as String,
            data['accountLabel'] as String? ?? '',
          )
        : l10n.communitySignedOut;
  }
  final status = switch (data['status']) {
    'confirmed' => l10n.checkinConfirmed,
    'already' => l10n.checkinAlready,
    'ended' => l10n.checkinEnded,
    'unsupported' => l10n.checkinUnsupported,
    'cancelled' => l10n.checkinCancelled,
    'rejected' => l10n.checkinRejected,
    _ => l10n.checkinUnknown,
  };
  if (data['status'] == 'unknown' ||
      package.manifest.capability('attendance.checkin')?.schemaVersion !=
          '1.1') {
    return status;
  }
  return switch (data['reason']) {
    'location_required' => l10n.checkinLocationRequired,
    'location_rejected' => l10n.checkinLocationRejected,
    'face_required' => l10n.checkinFaceRequired,
    'photo_required' => l10n.checkinPhotoRequired,
    'verification_required' => l10n.checkinVerificationRequired,
    'requirements_unknown' => l10n.checkinRequirementsUnknown,
    'activity_unsupported' => l10n.checkinActivityUnsupported,
    'qr_expired' => l10n.checkinQrExpired,
    'request_failed' => l10n.checkinPreflightFailed,
    'submission_rejected' => l10n.checkinRejected,
    _ => status,
  };
}
