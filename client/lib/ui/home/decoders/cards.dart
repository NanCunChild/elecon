/// ADR-066: domain decoder preserving missing-value semantics.
library;

import '../models.dart';
import 'values.dart';

CardBalance? cardBalanceFromDynamic(Object? raw) {
  final map = asStringKeyedMap(raw);
  if (map == null) return null;
  final cardNumber = map['cardNumber'];
  final balanceMap = asStringKeyedMap(map['balance']);
  final amountMinor = asInt(balanceMap?['amountMinor']);
  final currency = balanceMap?['currency']?.toString();
  if ((map.containsKey('cardNumber') &&
          (cardNumber is! String || cardNumber.isEmpty)) ||
      amountMinor == null ||
      currency == null ||
      !currencyPattern.hasMatch(currency)) {
    return null;
  }
  final lastMap = asStringKeyedMap(map['lastTransaction']);
  return CardBalance(
    cardNumber: cardNumber as String?,
    cardNumberMasked: map['cardNumberMasked']?.toString(),
    cardType: map['cardType']?.toString(),
    accountType: map['accountType']?.toString(),
    campus: map['campus']?.toString(),
    wallet: map['wallet']?.toString(),
    status: map['status']?.toString(),
    balanceUpdatedAt: map['balanceUpdatedAt']?.toString(),
    snapshotAt: map['snapshotAt']?.toString(),
    errorStatus: map['errorStatus']?.toString(),
    balance: CardBalanceBalance(amountMinor: amountMinor, currency: currency),
    lastTransaction: lastMap == null
        ? null
        : CardBalanceLastTransaction(
            amountMinor: asInt(lastMap['amountMinor']),
            currency: lastMap['currency']?.toString(),
            time: lastMap['time']?.toString(),
            merchant: lastMap['merchant']?.toString(),
          ),
  );
}

CardTransactions? cardTransactionsFromDynamic(Object? raw) {
  final map = asStringKeyedMap(raw);
  if (map == null) return null;
  final cardNumber = map['cardNumber'];
  final itemsRaw = map['items'];
  if ((map.containsKey('cardNumber') &&
          (cardNumber is! String || cardNumber.isEmpty)) ||
      itemsRaw is! List) {
    return null;
  }
  final items = <CardTransactionsItems>[];
  for (final rawItem in itemsRaw) {
    final item = _cardTransactionItem(rawItem);
    if (item != null) items.add(item);
  }
  return CardTransactions(
    cardNumber: cardNumber as String?,
    cardNumberMasked: map['cardNumberMasked']?.toString(),
    cardType: map['cardType']?.toString(),
    accountType: map['accountType']?.toString(),
    campus: map['campus']?.toString(),
    wallet: map['wallet']?.toString(),
    page: asInt(map['page']),
    size: asInt(map['size']),
    cursor: map['cursor']?.toString(),
    total: asInt(map['total']),
    hasNext: map['hasNext'] is bool ? map['hasNext'] as bool : null,
    windowStart: map['windowStart']?.toString(),
    windowEnd: map['windowEnd']?.toString(),
    snapshotAt: map['snapshotAt']?.toString(),
    items: items,
  );
}

CardTransactionsItems? _cardTransactionItem(Object? raw) {
  final map = asStringKeyedMap(raw);
  if (map == null) return null;
  final time = map['time']?.toString();
  final amountMinor = asNonNegativeInt(map['amountMinor']);
  final currency = map['currency']?.toString();
  final direction = map['direction']?.toString();
  if (time == null ||
      time.isEmpty ||
      DateTime.tryParse(time) == null ||
      amountMinor == null ||
      currency == null ||
      !currencyPattern.hasMatch(currency) ||
      direction == null ||
      !_cardDirections.contains(direction)) {
    return null;
  }
  return CardTransactionsItems(
    time: time,
    transactionId: map['transactionId']?.toString(),
    postedAt: map['postedAt']?.toString(),
    amountMinor: amountMinor,
    currency: currency,
    direction: direction,
    merchant: map['merchant']?.toString(),
    location: map['location']?.toString(),
    status: map['status']?.toString(),
    balanceAfterMinor: asInt(map['balanceAfterMinor']),
    type: map['type']?.toString(),
  );
}

const _cardDirections = {
  'debit',
  'credit',
  'refund',
  'reversal',
  'freeze',
  'transfer',
  'subsidy',
  'unknown',
};
