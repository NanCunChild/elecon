/// ADR-066: a feature's immutable, approved source follows every query and cache read.
library;

import '../core/adapter_service.dart';
import 'session_controller.dart';

class CapabilitySource {
  const CapabilitySource({required this.packageId, required this.digest});
  final String packageId;
  final String digest;

  @override
  bool operator ==(Object other) =>
      other is CapabilitySource &&
      packageId == other.packageId &&
      digest == other.digest;
  @override
  int get hashCode => Object.hash(packageId, digest);
}

/// Domain widgets use the same operations for default and explicitly bound sources.
/// The session remains the authority for identity, installation and cancellation.
class CapabilityQueries {
  const CapabilityQueries(this.session, {this.source});
  final SessionController session;
  final CapabilitySource? source;

  /// Presentation metadata only. Execution still goes through the session's
  /// authorization and cancellation gates; this does not grant permission.
  Future<String?> schemaVersion(String capability) async {
    final schoolId = session.selectedSchool?.id;
    final generation = session.trustedScriptViewGeneration;
    if (schoolId == null) return null;
    try {
      final registry = await session.scriptRegistry;
      if (session.selectedSchool?.id != schoolId ||
          session.trustedScriptViewGeneration != generation) {
        return null;
      }
      final installation = source == null
          ? null
          : registry.find(source!.packageId);
      final package = source == null
          ? registry.provider(schoolId, capability)
          : installation?.package;
      if (package == null ||
          package.requiresUpdate ||
          package.manifest.schoolId != schoolId ||
          (source != null &&
              (installation?.enabled != true ||
                  package.digest != source!.digest))) {
        return null;
      }
      return package.manifest.capability(capability)?.schemaVersion;
    } catch (_) {
      // Missing/unavailable provenance cannot opt into a new field's meaning.
      return null;
    }
  }

  Future<CapabilityRun> runCapability(
    String capability, {
    Map<String, dynamic>? params,
    bool interactive = true,
    ScriptRunCancellation? cancellation,
  }) => source == null
      ? session.runCapability(
          capability,
          params: params,
          interactive: interactive,
          cancellation: cancellation,
        )
      : session.runTrustedScript(
          source!.packageId,
          capability,
          expectedDigest: source!.digest,
          params: params,
          interactive: interactive,
          cancellation: cancellation,
        );

  Future<ScriptCachedData?> cachedCapability(
    String capability, {
    Map<String, dynamic>? params,
  }) => session.cachedCapability(
    capability,
    params: params,
    packageId: source?.packageId,
    expectedDigest: source?.digest,
  );

  Future<ScriptCachedData?> latestCachedCapability(String capability) =>
      session.latestCachedCapability(
        capability,
        packageId: source?.packageId,
        expectedDigest: source?.digest,
      );

  Future<bool> capabilityNeedsConfiguration(
    String capability, {
    Map<String, dynamic>? params,
  }) => session.capabilityNeedsConfiguration(
    capability,
    params: params,
    packageId: source?.packageId,
    expectedDigest: source?.digest,
  );
}
