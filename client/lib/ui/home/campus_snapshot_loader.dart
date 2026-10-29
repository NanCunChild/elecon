/// 首页 [CampusSnapshot] 装配：经 [SessionController.runCapability] 拉公开能力。
///
/// MVP-A：仅 `notice.list`（无凭证）；其它卡片字段留空。失败上抛，由首页 error 态承接。
library;

import '../../session/session_controller.dart';
import 'schema_decode.dart';
import 'models.dart';

/// 从当前会话学校跑 `notice.list`，组装首页快照。
Future<CampusSnapshot> loadCampusSnapshot(SessionController session) async {
  final school = session.selectedSchool;
  if (school == null) {
    throw StateError('未选校');
  }
  final run = await session.runCapability('notice.list');
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
