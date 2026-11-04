/// 首页 [CampusSnapshot] 装配：经 [SessionController.runCapability] 拉公开能力。
///
/// MVP-A：仅 `notice.list`（无凭证）；其它卡片字段留空。失败上抛，由首页 error 态承接。
library;

import '../../session/session_controller.dart';
import 'schema_decode.dart';
import 'models.dart';

/// 从当前会话学校跑 `notice.list`，组装首页快照。
Future<CampusSnapshot> loadCampusSnapshot(
  SessionController session, {
  bool preferCacheOnly = false,
  bool refreshNotices = false,
}) async {
  final school = session.selectedSchool;
  final generation = session.trustedScriptViewGeneration;
  if (school == null) {
    throw StateError('未选校');
  }
  // The fixed home view has no notice filter; restore the script's default query.
  final cached = await session.latestCachedCapability('notice.list');
  final cachedNotices = cached == null
      ? null
      : noticeListFromDynamic(cached.data);
  final capabilities = {
    ...school.capabilityCredentials.keys,
    ...await session.trustedScriptCapabilities(),
  };
  String? homeTitle;
  try {
    final legacyTitle = (await session.scriptRegistry).homeTitleForSchool(
      school.id,
      packageId: school.adapterId.startsWith('script:')
          ? school.adapterId.substring(7)
          : null,
    );
    homeTitle = school.institutionId == null ? legacyTitle : school.displayName;
  } catch (_) {
    // Optional presentation metadata must not prevent legacy data loading.
  }
  DateTime? updatedAt = cached?.fetchedAt;
  for (final data in await Future.wait([
    for (final capability in capabilities)
      if (capability != 'notice.list' && capability != 'climate.command')
        session.latestCachedCapability(capability),
  ])) {
    if (data != null &&
        (updatedAt == null || data.fetchedAt.isAfter(updatedAt))) {
      updatedAt = data.fetchedAt;
    }
  }
  if (cachedNotices != null && !refreshNotices) {
    return CampusSnapshot(
      schoolName: school.displayName,
      schoolType: school.typeName,
      homeTitle: homeTitle,
      updatedAt: updatedAt,
      notices: cachedNotices,
      supportedCapabilities: capabilities,
    );
  }
  // ADR-060: reading a desktop is strictly local, including packages that
  // deliberately omit preload. Background work starts after its first frame.
  if (preferCacheOnly) {
    return CampusSnapshot(
      schoolName: school.displayName,
      schoolType: school.typeName,
      homeTitle: homeTitle,
      updatedAt: updatedAt,
      supportedCapabilities: capabilities,
    );
  }
  if (session.selectedSchool?.id != school.id ||
      session.trustedScriptViewGeneration != generation) {
    throw StateError('school_changed');
  }
  final run = await session.runCapability('notice.list', interactive: false);
  if (!run.ok) {
    return CampusSnapshot(
      schoolName: school.displayName,
      schoolType: school.typeName,
      homeTitle: homeTitle,
      updatedAt: updatedAt,
      notices: cachedNotices,
      supportedCapabilities: {
        ...school.capabilityCredentials.keys,
        ...await session.trustedScriptCapabilities(),
      },
    );
  }
  final notices = noticeListFromDynamic(run.data);
  if (notices == null) {
    throw StateError('notice.list 产出无法解码');
  }
  return CampusSnapshot(
    schoolName: school.displayName,
    schoolType: school.typeName,
    homeTitle: homeTitle,
    updatedAt: DateTime.now().toUtc(),
    notices: notices,
    supportedCapabilities: {
      ...run.supportedCapabilities,
      ...await session.trustedScriptCapabilities(),
    },
  );
}
