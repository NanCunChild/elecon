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

  Future<CapabilityRun> runCapability(
    String capability, {
    Map<String, dynamic>? params,
    bool interactive = true,
  }) => source == null
      ? session.runCapability(
          capability,
          params: params,
          interactive: interactive,
        )
      : session.runTrustedScript(
          source!.packageId,
          capability,
          expectedDigest: source!.digest,
          params: params,
          interactive: interactive,
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
