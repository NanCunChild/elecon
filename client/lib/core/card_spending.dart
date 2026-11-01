import 'package:elecon_contract/card_transactions.dart';

/// Derived from the existing transaction contract; no school-specific rules.
/// Amounts remain integer minor units and currencies are never combined.
class CardSpendingSummary {
  const CardSpendingSummary(this.currencies);

  final List<CardCurrencySpending> currencies;

  static CardSpendingSummary fromTransactions(
    Iterable<CardTransactionsItems> items, {
    required DateTime from,
    required DateTime to,
  }) {
    final first = DateTime(from.year, from.month, from.day);
    final end = DateTime(to.year, to.month, to.day + 1);
    final totals = <String, Map<String?, int>>{};
    final daily = <String, Map<DateTime, int>>{};
    final seen = <(String, String)>{};
    for (final item in items) {
      // Refunds cannot be assigned to an original purchase under v1.0. They
      // are not subtracted from a different day's or merchant's spending.
      if (item.direction != 'debit' ||
          item.amountMinor <= 0 ||
          (item.status != null && item.status != 'final')) {
        continue;
      }
      final time = DateTime.tryParse(item.time)?.toLocal();
      if (time == null || time.isBefore(first) || !time.isBefore(end)) continue;
      final id = item.transactionId;
      // Only an explicit source identity permits deduplication. Identical
      // anonymous purchases may both be real and must not be collapsed.
      if (id != null && id.isNotEmpty && !seen.add((item.currency, id))) {
        continue;
      }
      final merchant = item.merchant?.trim();
      final group = merchant == null || merchant.isEmpty ? null : merchant;
      final groups = totals.putIfAbsent(item.currency, () => {});
      groups.update(
        group,
        (value) => value + item.amountMinor,
        ifAbsent: () => item.amountMinor,
      );
      final day = DateTime(time.year, time.month, time.day);
      final days = daily.putIfAbsent(item.currency, () => {});
      days.update(
        day,
        (value) => value + item.amountMinor,
        ifAbsent: () => item.amountMinor,
      );
    }
    final codes = totals.keys.toList()..sort();
    return CardSpendingSummary(
      List.unmodifiable([
        for (final code in codes)
          CardCurrencySpending(
            currency: code,
            merchants: List.unmodifiable(
              totals[code]!.entries
                  .map((entry) => CardMerchantSpending(entry.key, entry.value))
                  .toList()
                ..sort((a, b) {
                  final amount = b.amountMinor.compareTo(a.amountMinor);
                  return amount != 0
                      ? amount
                      : (a.merchant ?? '').compareTo(b.merchant ?? '');
                }),
            ),
            days: List.unmodifiable([
              for (
                var day = first;
                day.isBefore(end);
                day = DateTime(day.year, day.month, day.day + 1)
              )
                CardDaySpending(day, daily[code]![day] ?? 0),
            ]),
          ),
      ]),
    );
  }
}

class CardCurrencySpending {
  const CardCurrencySpending({
    required this.currency,
    required this.merchants,
    required this.days,
  });

  final String currency;
  final List<CardMerchantSpending> merchants;
  final List<CardDaySpending> days;
  int get amountMinor =>
      merchants.fold(0, (sum, item) => sum + item.amountMinor);
}

class CardMerchantSpending {
  const CardMerchantSpending(this.merchant, this.amountMinor);
  final String? merchant;
  final int amountMinor;
}

class CardDaySpending {
  const CardDaySpending(this.date, this.amountMinor);
  final DateTime date;
  final int amountMinor;
}
