// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class CardQr {
  const CardQr({
    required this.imageBase64,
    required this.issuedAt,
    required this.expiresAt,
    this.purpose,
  });

  /// 学校返回的 PNG 图片标准 base64，不含 data URI 前缀；最多 256 KiB。仅供当前前台页面短时显示，不写缓存或日志。
  final String imageBase64;
  /// 脚本取得图片的时刻，RFC3339；不声称源站签发时刻。
  final String issuedAt;
  /// 客户端停止显示的截止时刻，RFC3339，须晚于 issuedAt；非学校承诺的有效期，宿主最多显示 60 秒。
  final String expiresAt;
  /// 学校声明的用途文字，例如校园身份或校园卡；缺失则不推断支付用途。
  final String? purpose;
}
