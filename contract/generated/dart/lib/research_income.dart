// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class ResearchIncome {
  const ResearchIncome({
    this.items,
  });

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

  final String? month;
  final int? amountMinor;
  final String? currency;
  final String? status;
  final String? source;
}
