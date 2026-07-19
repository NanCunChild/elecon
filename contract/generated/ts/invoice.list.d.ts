// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface InvoiceList {
  items?: InvoiceListItems[];
}

export interface InvoiceListItems {
  invoiceNo?: string;
  amountMinor?: number;
  currency?: string;
  issuedAt?: string;
  status?: "issued" | "voided" | "processing" | "unknown";
  downloadUrl?: string;
}
