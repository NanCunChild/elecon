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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _phase == QueryPhase.idle) _load();
    });
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
      summary: CardSummary(l10n.phoneDirectoryHint),
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
                PhoneDirectoryView(key: ValueKey(data), directory: data),
              ],
            ),
    );
  }
}

class PhoneDirectoryView extends StatefulWidget {
  const PhoneDirectoryView({super.key, required this.directory, this.dial});

  final DirectoryPhones directory;
  final Future<bool> Function(String phone)? dial;

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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final categories = widget.directory.items
        .map((i) => i.category)
        .toSet()
        .toList();
    final words = _query.trim().toLowerCase().split(RegExp(r'\s+'));
    final matches = widget.directory.items.where((item) {
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.phoneDirectoryVerified(widget.directory.verifiedDate),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        TextButton.icon(
          onPressed: () => _copy(widget.directory.sourceUrl),
          icon: const Icon(Icons.link),
          label: Text(l10n.phoneDirectorySource),
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
          }),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: const Key('phone-category'),
          initialValue: _category ?? '',
          isExpanded: true,
          decoration: InputDecoration(labelText: l10n.phoneDirectoryCategory),
          items: [
            DropdownMenuItem(value: '', child: Text(l10n.phoneDirectoryAll)),
            for (final category in categories)
              DropdownMenuItem(
                value: category,
                child: Text(
                  category,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (value) => setState(() {
            _category = value == '' ? null : value;
            _limit = 40;
          }),
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
