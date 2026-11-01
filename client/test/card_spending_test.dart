import 'package:elecon/core/card_spending.dart';
import 'package:elecon_contract/card_transactions.dart';
import 'package:flutter_test/flutter_test.dart';

CardTransactionsItems item({
  String? id,
  String direction = 'debit',
  String? status,
  int amount = 100,
  String currency = 'CNY',
  String? merchant = 'Synthetic dining hall',
  DateTime? time,
}) => CardTransactionsItems(
  time: (time ?? DateTime(2026, 11, 1, 12)).toUtc().toIso8601String(),
  transactionId: id,
  direction: direction,
  status: status,
  amountMinor: amount,
  currency: currency,
  merchant: merchant,
);

CardSpendingSummary summarize(Iterable<CardTransactionsItems> items) =>
    CardSpendingSummary.fromTransactions(
      items,
      from: DateTime(2026, 11, 1),
      to: DateTime(2026, 11, 3),
    );

void main() {
  test('spending excludes credits, refunds and non-final known states', () {
    final summary = summarize([
      item(amount: 123),
      item(status: 'final', amount: 456),
      for (final direction in [
        'credit',
        'refund',
        'reversal',
        'freeze',
        'transfer',
        'subsidy',
        'unknown',
      ])
        item(direction: direction, amount: 9999),
      for (final status in ['pending', 'failed', 'cancelled', 'unknown'])
        item(status: status, amount: 9999),
      item(amount: -100),
      item(amount: 0),
    ]);
    expect(summary.currencies.single.amountMinor, 579);
    expect(summary.currencies.single.days.map((day) => day.amountMinor), [
      579,
      0,
      0,
    ]);
  });

  test(
    'date window uses inclusive local days and explicit identities only',
    () {
      final summary = summarize([
        item(time: DateTime(2026, 10, 31, 23, 59, 59), amount: 9999),
        item(id: 'same', time: DateTime(2026, 11, 1)),
        item(id: 'same', time: DateTime(2026, 11, 1)),
        item(time: DateTime(2026, 11, 3, 23, 59, 59), amount: 200),
        item(time: DateTime(2026, 11, 3, 23, 59, 59), amount: 200),
        item(time: DateTime(2026, 11, 4), amount: 9999),
      ]);
      expect(summary.currencies.single.amountMinor, 500);
      expect(summary.currencies.single.days.map((day) => day.amountMinor), [
        100,
        0,
        400,
      ]);
    },
  );

  test('currencies stay separate and absent merchant stays unknown', () {
    final summary = summarize([
      item(id: 'shared-id', currency: 'JPY', amount: 1234),
      item(id: 'shared-id', merchant: null, amount: 999),
      item(merchant: ' ', amount: 1),
      item(merchant: 'Synthetic shop', amount: 500),
    ]);
    expect(summary.currencies.map((data) => data.currency), ['CNY', 'JPY']);
    final cny = summary.currencies.first;
    expect(cny.amountMinor, 1500);
    expect(cny.merchants.first.merchant, isNull);
    expect(cny.merchants.first.amountMinor, 1000);
    expect(summary.currencies.last.amountMinor, 1234);
  });

  test('no spendable records produces no chart series', () {
    expect(summarize([item(direction: 'credit')]).currencies, isEmpty);
    expect(summarize([]).currencies, isEmpty);
  });
}
