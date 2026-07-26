// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class ResearchIncome {
  const ResearchIncome({
    this.items,
  });

  /// 科研收入记录列表；可选，缺失表示学校不提供。
  final List<ResearchIncomeItems>? items;
}

class ResearchIncomeItems {
  const ResearchIncomeItems({
    this.month,
    this.amountMinor,
    this.currency,
    this.status,
    this.source,
  });

  /// 收入归属月份；字符串格式未由当前契约限定。可选，缺失表示学校不提供。
  final String? month;
  /// 科研收入金额的最小货币单位整数（如人民币分）；不用浮点。
  final int? amountMinor;
  /// 收入金额的 ISO 4217 三字母大写货币码，如 CNY。
  final String? currency;
  /// 收入状态：pending=待处理，paid=已支付，failed=失败，unknown=未知；可选，缺失表示学校不提供。
  final String? status;
  /// 科研收入来源；可选，缺失表示学校不提供。
  final String? source;
}
