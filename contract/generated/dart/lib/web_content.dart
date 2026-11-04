// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class WebContent {
  const WebContent({
    required this.pageId,
    required this.status,
  });

  /// 本次显式打开的包内网页 id，必须与请求一致。
  final String pageId;
  /// completed 表示脚本有业务成功证据；cancelled 表示尚未提交；unknown 表示提交可能已发生且禁止自动重发。
  final String status;
}
