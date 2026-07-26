// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface InvoiceList {
  /** 发票记录列表；可选，缺失表示学校不提供。 */
  items?: InvoiceListItems[];
}

export interface InvoiceListItems {
  /** 发票号码；可选，缺失表示学校不提供。 */
  invoiceNo?: string;
  /** 发票金额的最小货币单位整数（如人民币分）；不用浮点。 */
  amountMinor?: number;
  /** 发票金额的 ISO 4217 三字母大写货币码，如 CNY。 */
  currency?: string;
  /** 发票开具时刻，RFC3339/UTC；可选，缺失表示学校不提供。 */
  issuedAt?: string;
  /** 发票状态：issued=已开具，voided=已作废，processing=处理中，unknown=未知；可选，缺失表示学校不提供。 */
  status?: "issued" | "voided" | "processing" | "unknown";
  /** 发票下载 URI；可选，缺失表示学校不提供。 */
  downloadUrl?: string;
}
