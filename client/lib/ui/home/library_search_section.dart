import 'package:elecon_contract/library_search.dart';
import 'package:elecon_contract/output_validator_registry.dart';
import 'package:flutter/material.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../session/session_scope.dart';
import '../../session/session_controller.dart';
import 'capability_source.dart';
import 'query_section.dart';
import 'section_card.dart';

LibrarySearch? librarySearchFromDynamic(Object? raw) {
  if (outputValidatorFor('elecon.library.search', '1.0')?.call(raw) != true) {
    return null;
  }
  final map = raw as Map;
  final items = (map['items'] as List).cast<Map>();
  if (items.map((e) => e['bookId']).toSet().length != items.length ||
      items.length > (map['size'] as int) ||
      (map['total'] != null && (map['total'] as int) < items.length) ||
      (map['query'] as String).trim().isEmpty) {
    return null;
  }
  return LibrarySearch(
    query: map['query'],
    page: map['page'],
    size: map['size'],
    hasNext: map['hasNext'],
    total: map['total'],
    items: [
      for (final row in items)
        LibrarySearchItems(
          bookId: row['bookId'],
          title: row['title'],
          author: row['author'],
          isbn: row['isbn'],
          publisher: row['publisher'],
          callNumber: row['callNumber'],
        ),
    ],
  );
}

class LibrarySearchSection extends StatefulWidget {
  const LibrarySearchSection({super.key});
  @override
  State<LibrarySearchSection> createState() => _LibrarySearchSectionState();
}

class _LibrarySearchSectionState extends State<LibrarySearchSection>
    with CachedQuerySection<LibrarySearchSection, LibrarySearch> {
  final _query = TextEditingController();
  LibrarySearch? _data;
  QueryPhase _phase = QueryPhase.idle;
  String? _error;
  int _request = 0;
  bool _loading = false;
  bool _editing = false;
  Map<String, dynamic>? _submitted;
  @override
  Map<String, dynamic>? get cacheParams => _submitted;
  @override
  String get cacheCapability => 'library.search';
  @override
  LibrarySearch? decodeCache(Object? raw) => librarySearchFromDynamic(raw);
  @override
  void applyCache(LibrarySearch data) {
    if (_loading ||
        _editing ||
        data.query != restoredParams['query'] ||
        data.page != restoredParams['page'] ||
        data.size != restoredParams['size']) {
      return;
    }
    _submitted = Map.of(restoredParams);
    _data = data;
    _phase = QueryPhase.loaded;
    _query.text = data.query;
  }

  @override
  void clearCache() {
    _request++;
    _submitted = null;
    _loading = false;
    _editing = false;
    _data = null;
    _phase = QueryPhase.idle;
    _error = null;
    _query.clear();
  }

  @override
  void dispose() {
    _request++;
    _query.dispose();
    super.dispose();
  }

  Future<void> _load({int page = 1, bool configure = false}) async {
    final query = _query.text.trim();
    if (query.isEmpty || _loading) return;
    FocusScope.of(context).unfocus();
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final source = CapabilitySourceScope.maybeOf(context)?.source;
    final request = ++_request;
    cacheRead++; // A pending cache read must not replace the submitted query.
    setState(() {
      _loading = true;
      _editing = false;
      _submitted = {'query': query, 'page': page, 'size': 10};
      if (_data?.query != query) {
        _data = null;
        cacheFetchedAt = null;
      }
      _phase = QueryPhase.loading;
      _error = null;
    });
    final result = await runDecoded<LibrarySearch>(
      context,
      session,
      cacheCapability,
      params: {..._submitted!, if (configure) 'configure': true},
      decode: decodeCache,
    );
    if (!isCurrentQuery(this, session, generation, source) ||
        request != _request) {
      return;
    }
    setState(() {
      _loading = false;
      if (result.data != null &&
          result.data!.query == query &&
          result.data!.page == page &&
          result.data!.size == 10) {
        _data = result.data;
        cacheFetchedAt = DateTime.now();
        cacheStale = false;
        _phase = QueryPhase.loaded;
      } else {
        // A failed page request keeps the displayed page as the cache address.
        // Otherwise a later unrelated cache notification could clear it.
        if (_data != null) {
          _submitted = {
            'query': _data!.query,
            'page': _data!.page,
            'size': _data!.size,
          };
        }
        _phase = result.needConfiguration
            ? QueryPhase.needConfiguration
            : result.needLogin
            ? QueryPhase.needLogin
            : QueryPhase.error;
        _error = result.error ?? AppLocalizations.of(context).campusLoadFailed;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context), data = _data;
    return withCacheTime(
      SectionCard(
        title: l10n.librarySearchTitle,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _query,
              enabled: !_loading,
              onChanged: (_) {
                _editing = true;
                cacheRead++;
              },
              maxLength: 200,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: l10n.librarySearchHint,
                counterText: '',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(28),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: Theme.of(context).colorScheme.surfaceContainerHigh,
              ),
              onSubmitted: (_) => _load(),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton.icon(
                onPressed: _phase == QueryPhase.loading ? null : () => _load(),
                icon: const Icon(Icons.search),
                label: Text(l10n.librarySearchAction),
              ),
            ),
            QueryPhaseBody(
              phase: _phase,
              error: _error,
              onConfigure: () => _load(configure: true),
              onLogin: () async {
                final session = SessionScope.of(context);
                final generation = session.trustedScriptViewGeneration;
                final source = CapabilitySourceScope.maybeOf(context)?.source;
                final ok = await promptVisibleLogin(
                  context,
                  session,
                  capability: cacheCapability,
                );
                if (ok && isCurrentQuery(this, session, generation, source)) {
                  await _load();
                }
              },
            ),
            if (data != null) ...[
              if (data.items.isEmpty) Text(l10n.librarySearchEmpty),
              for (final item in data.items) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SelectableText(
                        item.title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      for (final field in [
                        (l10n.libraryAuthor, item.author),
                        (l10n.libraryPublisher, item.publisher),
                        (l10n.libraryIsbn, item.isbn),
                        (l10n.libraryCallNumber, item.callNumber),
                      ])
                        if (field.$2?.trim().isNotEmpty == true)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: '${field.$1}  ',
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  TextSpan(text: field.$2),
                                ],
                              ),
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                    ],
                  ),
                ),
                const Divider(height: 1),
              ],
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).previousPageTooltip,
                    onPressed: data.page > 1 && _phase != QueryPhase.loading
                        ? () {
                            _query.text = data.query;
                            _load(page: data.page - 1);
                          }
                        : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text('${data.page}'),
                  IconButton(
                    tooltip: MaterialLocalizations.of(context).nextPageTooltip,
                    onPressed: data.hasNext && _phase != QueryPhase.loading
                        ? () {
                            _query.text = data.query;
                            _load(page: data.page + 1);
                          }
                        : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
