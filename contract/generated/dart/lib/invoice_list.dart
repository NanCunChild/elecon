// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class InvoiceList {
  const InvoiceList({
    this.items,
  });

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

  final String? invoiceNo;
  final int? amountMinor;
  final String? currency;
  final String? issuedAt;
  final String? status;
  final String? downloadUrl;
}
