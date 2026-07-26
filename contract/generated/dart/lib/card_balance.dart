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

  /// 校内作用域的一卡通卡号。
  final String cardNumber;
  /// 脱敏后的一卡通卡号；可选，缺失表示学校不提供。
  final String? cardNumberMasked;
  /// 一卡通卡片类型；可选，缺失表示学校不提供。
  final String? cardType;
  /// 一卡通账户类型；可选，缺失表示学校不提供。
  final String? accountType;
  /// 一卡通所属校区；可选，缺失表示学校不提供。
  final String? campus;
  /// 余额所属钱包；可选，缺失表示学校不提供。
  final String? wallet;
  /// 一卡通状态：active=正常，frozen=冻结，lost=挂失，cancelled=注销，unknown=未知；可选，缺失表示学校不提供。
  final String? status;
  final String? balanceUpdatedAt;
  final String? snapshotAt;
  final String? errorStatus;
  /// 一卡通当前余额，使用整数最小货币单位和三字母货币码表示。
  final CardBalanceBalance balance;
  /// 最近一笔一卡通交易摘要；可选，缺失表示学校不提供。
  final CardBalanceLastTransaction? lastTransaction;
}

class CardBalanceBalance {
  const CardBalanceBalance({
    required this.amountMinor,
    required this.currency,
  });

  /// 最小货币单位，如分
  final int amountMinor;
  /// ISO 4217 三字母大写货币码，如 CNY。
  final String currency;
}

class CardBalanceLastTransaction {
  const CardBalanceLastTransaction({
    this.amountMinor,
    this.currency,
    this.time,
    this.merchant,
  });

  /// 该笔交易金额的最小货币单位整数（如人民币分）；不用浮点。
  final int? amountMinor;
  /// 该笔交易的 ISO 4217 三字母大写货币码，如 CNY。
  final String? currency;
  final String? time;
  /// 该笔交易的商户名称；可选，缺失表示学校不提供。
  final String? merchant;
}
