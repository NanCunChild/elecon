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
  /// 交易所属钱包；可选，缺失表示学校不提供。
  final String? wallet;
  /// 当前结果页码，从 1 开始；可选，缺失表示该数据源不使用页码分页。
  final int? page;
  /// 当前分页的每页条数；可选，缺失表示该数据源不提供。
  final int? size;
  final String? cursor;
  /// 符合条件的交易总条数；可选，缺失表示学校不提供。
  final int? total;
  /// 是否还有下一批交易；可选，缺失表示学校不提供。
  final bool? hasNext;
  final String? windowStart;
  final String? windowEnd;
  final String? snapshotAt;
  /// 一卡通交易记录列表。
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

  /// 交易发生时刻，RFC3339/UTC。
  final String time;
  /// 校内作用域的交易标识；可选，缺失表示学校不提供。
  final String? transactionId;
  /// 交易入账时刻，RFC3339/UTC；可选，缺失表示学校不提供。
  final String? postedAt;
  /// 最小货币单位（如分），非负；收支方向由 direction 表示
  final int amountMinor;
  /// 交易金额的 ISO 4217 三字母大写货币码，如 CNY。
  final String currency;
  /// debit=支出 credit=充值/入账
  final String direction;
  /// 交易商户名称；可选，缺失表示学校不提供。
  final String? merchant;
  /// 交易地点；可选，缺失表示学校不提供。
  final String? location;
  /// 交易状态：final=已完成，pending=处理中，failed=失败，cancelled=已取消，unknown=未知；可选，缺失表示学校不提供。
  final String? status;
  /// 本笔交易后余额（最小货币单位）；可选
  final int? balanceAfterMinor;
  /// 交易类型原文/归类；可选
  final String? type;
}
