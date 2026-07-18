// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class CardTransactions {
  const CardTransactions({
    required this.cardNumber,
    this.cardNumberMasked,
    this.cardType,
    this.accountType,
    this.campus,
    this.wallet,
    this.page,
    this.size,
    this.cursor,
    this.total,
    this.hasNext,
    this.windowStart,
    this.windowEnd,
    this.snapshotAt,
    required this.items,
  });

  final String cardNumber;
  final String? cardNumberMasked;
  final String? cardType;
  final String? accountType;
  final String? campus;
  final String? wallet;
  final int? page;
  final int? size;
  final String? cursor;
  final int? total;
  final bool? hasNext;
  final String? windowStart;
  final String? windowEnd;
  final String? snapshotAt;
  final List<CardTransactionsItems> items;
}

class CardTransactionsItems {
  const CardTransactionsItems({
    required this.time,
    this.transactionId,
    this.postedAt,
    required this.amountMinor,
    required this.currency,
    required this.direction,
    this.merchant,
    this.location,
    this.status,
    this.balanceAfterMinor,
    this.type,
  });

  final String time;
  final String? transactionId;
  final String? postedAt;
  /// 最小货币单位（如分），非负；收支方向由 direction 表示
  final int amountMinor;
  final String currency;
  /// debit=支出 credit=充值/入账
  final String direction;
  final String? merchant;
  final String? location;
  final String? status;
  /// 本笔交易后余额（最小货币单位）；可选
  final int? balanceAfterMinor;
  /// 交易类型原文/归类；可选
  final String? type;
}
