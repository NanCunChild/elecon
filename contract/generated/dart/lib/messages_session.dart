// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class MessagesSession {
  const MessagesSession({
    required this.serviceId,
    required this.serviceName,
    required this.status,
    this.accountId,
    this.accountLabel,
  });

  /// 脚本定义的稳定服务标识；与安装来源一起确定服务。
  final String serviceId;
  /// 服务的显示名称；纯文本。
  final String serviceName;
  /// authenticated 仅在源站核验账号后返回；signedOut 为本地无有效会话。
  final String status;
  /// 源站稳定账号 ID，按字符串处理；未登录时省略。
  final String? accountId;
  /// 当前账号展示名；未登录时省略。
  final String? accountLabel;
}
