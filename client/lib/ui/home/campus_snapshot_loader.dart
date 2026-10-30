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
}) async {
  final school = session.selectedSchool;
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
  if (cachedNotices != null) {
    return CampusSnapshot(
      schoolName: school.displayName,
      updatedAt: cached!.fetchedAt,
      notices: cachedNotices,
      supportedCapabilities: capabilities,
    );
  }
  // ADR-038: let the shared preload operation own first fetch so the homepage
  // does not race it with a duplicate request. Older packages retain direct load.
  var declaredPreload = false;
  if (preferCacheOnly) {
    try {
      final provider = (await session.scriptRegistry).provider(
        school.id,
        'notice.list',
      );
      declaredPreload =
          provider?.manifest.home.any(
            (item) => item.capability == 'notice.list' && item.preload,
          ) ??
          false;
    } catch (_) {
      // An unavailable optional registry must not break the legacy provider.
    }
  }
  if (declaredPreload) {
    return CampusSnapshot(
      schoolName: school.displayName,
      updatedAt: DateTime.now().toUtc(),
      supportedCapabilities: capabilities,
    );
  }
  final run = await session.runCapability('notice.list', interactive: false);
  if (!run.ok) {
    return CampusSnapshot(
      schoolName: school.displayName,
      updatedAt: DateTime.now().toUtc(),
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
    updatedAt: DateTime.now().toUtc(),
    notices: notices,
    supportedCapabilities: {
      ...run.supportedCapabilities,
      ...await session.trustedScriptCapabilities(),
    },
  );
}
