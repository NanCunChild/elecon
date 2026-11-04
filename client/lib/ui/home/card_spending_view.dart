import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/card_spending.dart';
import '../../l10n/gen/app_localizations.dart';
import 'display_date.dart';

/// Charts share the same loaded transactions as the list below them.
class CardSpendingView extends StatefulWidget {
  const CardSpendingView({
    super.key,
    required this.summary,
    required this.partial,
    this.onOpen,
  });

  final CardSpendingSummary summary;
  final bool partial;
  final VoidCallback? onOpen;

  @override
  State<CardSpendingView> createState() => _CardSpendingViewState();
}

class _CardSpendingViewState extends State<CardSpendingView> {
  String? _currency;
  bool _daily = false;

  @override
  Widget build(BuildContext context) {
    final currencies = widget.summary.currencies;
    if (currencies.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final data =
        currencies.where((item) => item.currency == _currency).firstOrNull ??
        currencies.first;
    return Card(
      key: const ValueKey('card-spending-chart'),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: InkWell(
        onTap: widget.onOpen,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.cardSpendingTitle, style: theme.textTheme.titleLarge),
              if (currencies.length > 1)
                DropdownButton<String>(
                  value: data.currency,
                  isExpanded: true,
                  hint: Text(l10n.cardSpendingCurrency),
                  items: [
                    for (final value in currencies)
                      DropdownMenuItem(
                        value: value.currency,
                        child: Text(value.currency),
                      ),
                  ],
                  onChanged: (value) => setState(() => _currency = value),
                ),
              const SizedBox(height: 8),
              Text(
                '${l10n.cardSpendingTotal} · ${formatCardMoney(context, data.amountMinor, data.currency)}',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  ChoiceChip(
                    label: Text(l10n.cardSpendingDistribution),
                    selected: !_daily,
                    onSelected: (_) => setState(() => _daily = false),
                  ),
                  ChoiceChip(
                    label: Text(l10n.cardSpendingDaily),
                    selected: _daily,
                    onSelected: (_) => setState(() => _daily = true),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (_daily)
                _DailySpendingChart(data: data)
              else
                for (final merchant in data.merchants)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          merchant.merchant ?? l10n.cardSpendingUnknownMerchant,
                        ),
                        Text(
                          '${formatCardMoney(context, merchant.amountMinor, data.currency)} · ${(100 * merchant.amountMinor / data.amountMinor).toStringAsFixed(1)}%',
                          style: theme.textTheme.bodySmall,
                        ),
                        const SizedBox(height: 4),
                        LinearProgressIndicator(
                          value: merchant.amountMinor / data.amountMinor,
                          minHeight: 8,
                          borderRadius: BorderRadius.circular(4),
                          semanticsLabel:
                              '${merchant.merchant ?? l10n.cardSpendingUnknownMerchant} · ${formatCardMoney(context, merchant.amountMinor, data.currency)}',
                        ),
                      ],
                    ),
                  ),
              if (widget.partial) ...[
                Text(
                  l10n.cardSpendingPartial,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
              ],
              Text(
                l10n.cardSpendingLoadedOnly,
                style: theme.textTheme.bodySmall,
              ),
              Text(
                l10n.cardSpendingLocalDates,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DailySpendingChart extends StatelessWidget {
  const _DailySpendingChart({required this.data});
  final CardCurrencySpending data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final days = data.days;
    final maximum = days.fold<int>(
      0,
      (max, day) => math.max(max, day.amountMinor),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          formatCardMoney(context, maximum, data.currency),
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        SizedBox(
          key: const ValueKey('card-spending-daily'),
          height: 140,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final day in days)
                Expanded(
                  child: Tooltip(
                    triggerMode: TooltipTriggerMode.tap,
                    message:
                        '${formatLocalDate(day.date)} · ${formatCardMoney(context, day.amountMinor, data.currency)}',
                    child: Semantics(
                      label: formatLocalDate(day.date),
                      value: formatCardMoney(
                        context,
                        day.amountMinor,
                        data.currency,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 1),
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: FractionallySizedBox(
                            widthFactor: 1,
                            heightFactor: maximum == 0
                                ? 0
                                : day.amountMinor / maximum,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary,
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(3),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        const SizedBox(height: 4),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 16,
          children: [
            if (days.isNotEmpty) Text(formatLocalDate(days.first.date)),
            if (days.length > 1) Text(formatLocalDate(days.last.date)),
          ],
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}

String formatCardMoney(BuildContext context, int amountMinor, String currency) {
  final format = NumberFormat.currency(
    locale: Localizations.localeOf(context).toString(),
    name: currency,
  );
  return format.format(amountMinor / math.pow(10, format.decimalDigits ?? 2));
}
