import 'package:elecon_contract/directory_phones.dart';
import 'package:elecon_contract/output_validator_registry.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import '../../session/session_scope.dart';
import 'capability_source.dart';
import 'query_section.dart';
import 'section_card.dart';

export 'package:elecon_contract/directory_phones.dart';

DirectoryPhones? phoneDirectoryFromDynamic(Object? raw) {
  if (outputValidatorFor('elecon.directory.phones', '1.0')?.call(raw) != true) {
    return null;
  }
  final data = raw as Map;
  final ids = <String>{};
  final items = <DirectoryPhonesItems>[];
  for (final row in (data['items'] as List).cast<Map>()) {
    if (!ids.add(row['id'] as String)) return null;
    items.add(
      DirectoryPhonesItems(
        id: row['id'] as String,
        name: row['name'] as String,
        category: row['category'] as String,
        phone: row['phone'] as String,
        sourceUrl: row['sourceUrl'] as String,
        campus: row['campus'] as String?,
        address: row['address'] as String?,
        note: row['note'] as String?,
      ),
    );
  }
  return DirectoryPhones(
    items: List.unmodifiable(items),
    sourceUrl: data['sourceUrl'] as String,
    verifiedDate: data['verifiedDate'] as String,
  );
}

/// No script URI-launch API: this surface only constructs tel URIs from the
/// validated phone field in response to a user pressing the call button.
Future<bool> openPhoneDialer(String phone) async {
  if (!RegExp(r'^\+?[0-9]{3,15}$').hasMatch(phone)) return false;
  try {
    return await launchUrl(
      Uri(scheme: 'tel', path: phone),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    return false;
  }
}

class PhoneDirectorySection extends StatefulWidget {
  const PhoneDirectorySection({super.key});

  @override
  State<PhoneDirectorySection> createState() => _PhoneDirectorySectionState();
}

class _PhoneDirectorySectionState extends State<PhoneDirectorySection>
    with CachedQuerySection<PhoneDirectorySection, DirectoryPhones> {
  DirectoryPhones? _data;
  QueryPhase _phase = QueryPhase.idle;
  String? _error;
  int _request = 0;
  bool _attemptedLoad = false;
  List<String> _recentIds = const [];

  @override
  String get cacheCapability => 'directory.phones';
  @override
  DirectoryPhones? decodeCache(Object? raw) => phoneDirectoryFromDynamic(raw);
  @override
  void applyCache(DirectoryPhones data) {
    _data = data;
    _phase = QueryPhase.loaded;
  }

  @override
  void clearCache() {
    _request++;
    _data = null;
    _phase = QueryPhase.idle;
    _error = null;
    _recentIds = const [];
    _attemptedLoad = false;
  }

  @override
  Future<void> restoreCache() async {
    final session = cacheSession;
    final generation = session?.trustedScriptViewGeneration;
    final dataGeneration = session?.trustedScriptDataGeneration;
    await super.restoreCache();
    if (!mounted ||
        session != cacheSession ||
        generation != session?.trustedScriptViewGeneration ||
        dataGeneration != session?.trustedScriptDataGeneration ||
        _data != null ||
        _phase != QueryPhase.idle ||
        _attemptedLoad) {
      return;
    }
    _attemptedLoad = true;
    await _load();
  }

  Future<void> _load() async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final dataGeneration = session.trustedScriptDataGeneration;
    final source = CapabilitySourceScope.maybeOf(context)?.source;
    final request = ++_request;
    setState(() => _phase = QueryPhase.loading);
    final result = await runDecoded(
      context,
      session,
      cacheCapability,
      params: const {},
      interactive: false,
      decode: decodeCache,
    );
    if (!isCurrentQuery(this, session, generation, source) ||
        dataGeneration != session.trustedScriptDataGeneration ||
        request != _request) {
      return;
    }
    setState(() {
      _phase = result.data == null ? QueryPhase.error : QueryPhase.loaded;
      _error = result.error;
      if (result.data != null) _data = result.data;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final data = _data;
    return SectionCard(
      title: l10n.phoneDirectoryTitle,
      trailing: SectionRefreshButton(
        onPressed: _phase == QueryPhase.loading ? null : _load,
      ),
      summary: data == null
          ? CardSummary(l10n.phoneDirectoryHint)
          : PhoneDirectorySummary(
              items: {
                for (final id in _recentIds)
                  for (final item in data.items.where(
                    (entry) => entry.id == id,
                  ))
                    item,
                ...data.items,
              }.take(3).toList(),
            ),
      child: data == null
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                QueryPhaseBody(phase: _phase, error: _error, onLogin: _load),
                if (_phase == QueryPhase.error)
                  TextButton(onPressed: _load, child: Text(l10n.commonRetry)),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_phase == QueryPhase.loading)
                  const LinearProgressIndicator(),
                if (_phase == QueryPhase.error)
                  Text(l10n.phoneDirectoryRefreshFailed),
                PhoneDirectoryView(
                  directory: data,
                  onMatchesChanged: (items) => setState(() {
                    _recentIds = items.take(2).map((item) => item.id).toList();
                  }),
                ),
              ],
            ),
    );
  }
}

/// A call target is an inner button, so opening the dialer does not also open
/// the outer card. The full directory remains available from the card header.
class PhoneDirectorySummary extends StatefulWidget {
  const PhoneDirectorySummary({super.key, required this.items, this.dial});

  final List<DirectoryPhonesItems> items;
  final Future<bool> Function(String phone)? dial;

  @override
  State<PhoneDirectorySummary> createState() => _PhoneDirectorySummaryState();
}

class _PhoneDirectorySummaryState extends State<PhoneDirectorySummary> {
  bool _dialing = false;

  Future<void> _call(String phone) async {
    if (_dialing) return;
    setState(() => _dialing = true);
    final ok = await (widget.dial ?? openPhoneDialer)(phone);
    if (!mounted) return;
    setState(() => _dialing = false);
    if (!ok) {
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.phoneDirectoryDialFailed),
          action: SnackBarAction(
            label: l10n.phoneDirectoryCopy,
            onPressed: () => Clipboard.setData(ClipboardData(text: phone)),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (widget.items.isEmpty) return Text(l10n.phoneDirectoryEmpty);
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final line = scaler.scale(theme.textTheme.bodyMedium!.fontSize!) * 1.5;
    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked = constraints.maxWidth < 360 * scaler.scale(1);
        final height = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : 216.0;
        final rowHeight = (stacked ? line * 2 + 8 : line + 12).clamp(
          48.0,
          160.0,
        );
        final count = stacked ? 1 : (height / rowHeight).floor().clamp(1, 3);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final item in widget.items.take(count))
              Flexible(
                child: Tooltip(
                  message: l10n.phoneDirectoryCall(item.phone),
                  child: InkWell(
                    key: ValueKey('summary-call-${item.id}'),
                    borderRadius: BorderRadius.circular(8),
                    onTap: _dialing ? null : () => _call(item.phone),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: height.clamp(0, 48).toDouble(),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Semantics(
                          label: [
                            item.name,
                            ?item.campus,
                            l10n.phoneDirectoryCall(item.phone),
                          ].join(' · '),
                          excludeSemantics: true,
                          child: stacked
                              ? Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Flexible(
                                      child: Text(
                                        [item.name, ?item.campus].join(' · '),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodyMedium,
                                      ),
                                    ),
                                    Flexible(child: _number(item.phone)),
                                  ],
                                )
                              : Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        [item.name, ?item.campus].join(' · '),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodyMedium,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Flexible(child: _number(item.phone)),
                                  ],
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _number(String phone) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Flexible(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: Text(
            phone,
            maxLines: 1,
            textDirection: TextDirection.ltr,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      ),
      const SizedBox(width: 8),
      const Icon(Icons.call_outlined, size: 18),
    ],
  );
}

class PhoneDirectoryView extends StatefulWidget {
  const PhoneDirectoryView({
    super.key,
    required this.directory,
    this.dial,
    this.onMatchesChanged,
  });

  final DirectoryPhones directory;
  final Future<bool> Function(String phone)? dial;
  final ValueChanged<List<DirectoryPhonesItems>>? onMatchesChanged;

  @override
  State<PhoneDirectoryView> createState() => _PhoneDirectoryViewState();
}

class _PhoneDirectoryViewState extends State<PhoneDirectoryView> {
  String _query = '';
  String? _category;
  int _limit = 40;
  bool _dialing = false;

  Future<void> _call(String phone) async {
    if (_dialing) return;
    setState(() => _dialing = true);
    final ok = await (widget.dial ?? openPhoneDialer)(phone);
    if (!mounted) return;
    setState(() => _dialing = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).phoneDirectoryDialFailed),
        ),
      );
    }
  }

  Future<void> _copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context).phoneDirectoryCopied),
      ),
    );
  }

  List<DirectoryPhonesItems> _matches() {
    final words = _query.trim().toLowerCase().split(RegExp(r'\s+'));
    return widget.directory.items.where((item) {
      if (_category != null && item.category != _category) return false;
      final text = [
        item.name,
        item.category,
        item.campus,
        item.address,
        item.note,
        item.phone,
        item.phone.replaceAll(RegExp(r'\D'), ''),
      ].whereType<String>().join(' ').toLowerCase();
      return words.every(
        (word) =>
            text.contains(word) ||
            (RegExp(r'^[+\d()（）\s-]+$').hasMatch(word) &&
                word.replaceAll(RegExp(r'\D'), '').isNotEmpty &&
                item.phone.contains(word.replaceAll(RegExp(r'\D'), ''))),
      );
    }).toList();
  }

  void _remember() {
    if (_query.trim().isNotEmpty || _category != null) {
      widget.onMatchesChanged?.call(_matches());
    }
  }

  Future<void> _chooseCategory(List<String> categories) async {
    final selection = await showDialog<String>(
      context: context,
      builder: (_) =>
          _PhoneCategoryDialog(categories: categories, selected: _category),
    );
    if (!mounted || selection == null) return;
    setState(() {
      _category = selection.isEmpty ? null : selection;
      _limit = 40;
      _remember();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final categories = widget.directory.items
        .map((i) => i.category)
        .toSet()
        .toList();
    final matches = _matches();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.phoneDirectoryVerified(widget.directory.verifiedDate),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        TextField(
          key: const Key('phone-search'),
          maxLength: 100,
          decoration: InputDecoration(
            labelText: l10n.phoneDirectorySearch,
            prefixIcon: const Icon(Icons.search),
            counterText: '',
          ),
          onChanged: (value) => setState(() {
            _query = value;
            _limit = 40;
            _remember();
          }),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          key: const Key('phone-category'),
          onPressed: () => _chooseCategory(categories),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${l10n.phoneDirectoryCategory} · ${_category ?? l10n.phoneDirectoryAll}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Icon(Icons.expand_more),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(l10n.phoneDirectoryCount(matches.length)),
        if (matches.isEmpty) Text(l10n.phoneDirectoryEmpty),
        for (final item in matches.take(_limit))
          ExpansionTile(
            key: ValueKey(item.id),
            tilePadding: EdgeInsets.zero,
            title: Text(item.name),
            subtitle: Text(
              [
                item.category,
                item.campus,
                item.phone,
              ].whereType<String>().join(' · '),
            ),
            trailing: IconButton(
              key: ValueKey('call-${item.id}'),
              tooltip: l10n.phoneDirectoryCall(item.phone),
              onPressed: _dialing ? null : () => _call(item.phone),
              icon: const Icon(Icons.call_outlined),
            ),
            expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton.icon(
                    key: ValueKey('dial-${item.id}'),
                    onPressed: _dialing ? null : () => _call(item.phone),
                    icon: const Icon(Icons.call_outlined),
                    label: Text(item.phone),
                  ),
                  IconButton(
                    tooltip: l10n.phoneDirectoryCopy,
                    onPressed: () => _copy(item.phone),
                    iconSize: 18,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    icon: const Icon(Icons.copy_outlined),
                  ),
                ],
              ),
              if (item.address != null) Text(item.address!),
              if (item.note != null) Text(item.note!),
              SelectableText(
                item.sourceUrl,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
            ],
          ),
        if (matches.length > _limit)
          TextButton(
            onPressed: () => setState(() => _limit += 40),
            child: Text(l10n.phoneDirectoryMore),
          ),
      ],
    );
  }
}

class _PhoneCategoryDialog extends StatefulWidget {
  const _PhoneCategoryDialog({required this.categories, this.selected});
  final List<String> categories;
  final String? selected;

  @override
  State<_PhoneCategoryDialog> createState() => _PhoneCategoryDialogState();
}

class _PhoneCategoryDialogState extends State<_PhoneCategoryDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final choices = [
      '',
      ...widget.categories.where(
        (category) =>
            category.toLowerCase().contains(_query.trim().toLowerCase()),
      ),
    ];
    return AlertDialog(
      title: Text(l10n.phoneDirectoryCategory),
      content: SizedBox(
        width: 420,
        height: (MediaQuery.sizeOf(context).height * .55).clamp(160, 480),
        child: Column(
          children: [
            TextField(
              key: const Key('phone-category-search'),
              decoration: InputDecoration(
                labelText: l10n.phoneDirectoryCategorySearch,
                prefixIcon: const Icon(Icons.search),
              ),
              onChanged: (query) => setState(() => _query = query),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: choices.length,
                itemBuilder: (context, index) {
                  final choice = choices[index];
                  final selected = choice == (widget.selected ?? '');
                  return ListTile(
                    title: Text(
                      choice.isEmpty ? l10n.phoneDirectoryAll : choice,
                    ),
                    selected: selected,
                    trailing: selected ? const Icon(Icons.check) : null,
                    onTap: () => Navigator.pop(context, choice),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
      ],
    );
  }
}
