// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class DiningSummary {
  const DiningSummary({
    this.items,
  });

  final List<DiningSummaryItems>? items;
}

class DiningSummaryItems {
  const DiningSummaryItems({
    this.merchant,
    this.amountMinor,
    this.currency,
    this.period,
    this.open,
  });

  final String? merchant;
  final int? amountMinor;
  final String? currency;
  final String? period;
  final bool? open;
}
