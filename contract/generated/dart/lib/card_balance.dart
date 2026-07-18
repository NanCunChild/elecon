// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class CardBalance {
  const CardBalance({
    required this.cardNumber,
    this.cardNumberMasked,
    this.cardType,
    this.accountType,
    this.campus,
    this.wallet,
    this.status,
    this.balanceUpdatedAt,
    this.snapshotAt,
    this.errorStatus,
    required this.balance,
    this.lastTransaction,
  });

  final String cardNumber;
  final String? cardNumberMasked;
  final String? cardType;
  final String? accountType;
  final String? campus;
  final String? wallet;
  final String? status;
  final String? balanceUpdatedAt;
  final String? snapshotAt;
  final String? errorStatus;
  final CardBalanceBalance balance;
  final CardBalanceLastTransaction? lastTransaction;
}

class CardBalanceBalance {
  const CardBalanceBalance({
    required this.amountMinor,
    required this.currency,
  });

  /// 最小货币单位，如分
  final int amountMinor;
  final String currency;
}

class CardBalanceLastTransaction {
  const CardBalanceLastTransaction({
    this.amountMinor,
    this.currency,
    this.time,
    this.merchant,
  });

  final int? amountMinor;
  final String? currency;
  final String? time;
  final String? merchant;
}
