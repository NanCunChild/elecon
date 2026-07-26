// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class InvoiceList {
  const InvoiceList({
    this.items,
  });

  /// 发票记录列表；可选，缺失表示学校不提供。
  final List<InvoiceListItems>? items;
}

class InvoiceListItems {
  const InvoiceListItems({
    this.invoiceNo,
    this.amountMinor,
    this.currency,
    this.issuedAt,
    this.status,
    this.downloadUrl,
  });

  /// 发票号码；可选，缺失表示学校不提供。
  final String? invoiceNo;
  /// 发票金额的最小货币单位整数（如人民币分）；不用浮点。
  final int? amountMinor;
  /// 发票金额的 ISO 4217 三字母大写货币码，如 CNY。
  final String? currency;
  /// 发票开具时刻，RFC3339/UTC；可选，缺失表示学校不提供。
  final String? issuedAt;
  /// 发票状态：issued=已开具，voided=已作废，processing=处理中，unknown=未知；可选，缺失表示学校不提供。
  final String? status;
  /// 发票下载 URI；可选，缺失表示学校不提供。
  final String? downloadUrl;
}
