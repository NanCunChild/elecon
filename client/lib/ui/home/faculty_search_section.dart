/// ADR-050: public faculty search; the selected school script owns the protocol.
library;

import 'package:elecon_contract/faculty_search.dart';
import 'package:elecon_contract/output_validator_registry.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import '../../session/session_scope.dart';
import 'section_card.dart';

export 'package:elecon_contract/faculty_search.dart';

typedef FacultySearchLoader =
    Future<FacultySearch?> Function(Map<String, dynamic> params);

/// Validate the whole page: dropping malformed rows would hide missing results.
FacultySearch? facultySearchFromDynamic(Object? raw) {
  if (outputValidatorFor('elecon.faculty.search', '1.0')?.call(raw) != true) {
    return null;
  }
  final data = raw as Map;
  final rows = data['items'] as List;
  final ids = <String>{};
  final items = <FacultySearchItems>[];
  for (final row in rows.cast<Map>()) {
    final id = row['id'] as String;
    if (!ids.add(id)) return null;
    items.add(
      FacultySearchItems(
        id: id,
        name: row['name'] as String,
        department: row['department'] as String?,
        title: row['title'] as String?,
        disciplines: (row['disciplines'] as List?)?.cast<String>(),
        researchAreas: (row['researchAreas'] as List?)?.cast<String>(),
        summary: row['summary'] as String?,
        profileUrl: row['profileUrl'] as String?,
      ),
    );
  }
  final pageSize = (data['pageSize'] as num).toInt();
  final total = (data['total'] as num?)?.toInt();
  if (items.length > pageSize || (total != null && total < items.length)) {
    return null;
  }
  return FacultySearch(
    items: items,
    page: (data['page'] as num).toInt(),
    pageSize: pageSize,
    hasMore: data['hasMore'] as bool,
    sourceSystem: data['sourceSystem'] as String,
    sourceUrl: data['sourceUrl'] as String,
    total: total,
  );
}

class FacultySearchSection extends StatefulWidget {
  const FacultySearchSection({super.key, this.loadSearch});

  final FacultySearchLoader? loadSearch;

  @override
  State<FacultySearchSection> createState() => _FacultySearchSectionState();
}

class _FacultySearchSectionState extends State<FacultySearchSection> {
  final _name = TextEditingController();
  final _researchArea = TextEditingController();
  SessionController? _session;
  String? _schoolId;
  int? _generation;
  bool _bound = false, _invalidated = false, _loading = false, _failed = false;
  int _requestId = 0;
  FacultySearch? _result;
  Map<String, dynamic>? _submitted;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = context
        .dependOnInheritedWidgetOfExactType<SessionScope>()
        ?.notifier;
    if (!_bound) {
      _bound = true;
      _session = session;
      _schoolId = session?.selectedSchool?.id;
      _generation = session?.trustedScriptViewGeneration;
    } else if (!identical(session, _session) ||
        _schoolId != session?.selectedSchool?.id ||
        _generation != session?.trustedScriptViewGeneration) {
      _requestId++;
      _invalidated = true;
      _result = null;
      _submitted = null;
      _loading = false;
      _failed = false;
      _name.clear();
      _researchArea.clear();
    }
  }

  bool get _canSearch =>
      !_invalidated &&
      !_loading &&
      (_name.text.trim().isNotEmpty || _researchArea.text.trim().isNotEmpty);

  Future<void> _submit() async {
    if (!_canSearch) return;
    FocusScope.of(context).unfocus();
    await _load({
      if (_name.text.trim().isNotEmpty) 'query': _name.text.trim(),
      if (_researchArea.text.trim().isNotEmpty)
        'researchArea': _researchArea.text.trim(),
      'page': 1,
      'pageSize': 10,
    });
  }

  Future<void> _load(Map<String, dynamic> params) async {
    if (_invalidated || _loading) return;
    final requestId = ++_requestId;
    setState(() {
      _loading = true;
      _failed = false;
      _result = null;
      _submitted = Map.unmodifiable(params);
    });
    FacultySearch? result;
    try {
      if (widget.loadSearch != null) {
        result = await widget.loadSearch!(params);
      } else if (_session != null) {
        final run = await _session!.runCapability(
          'faculty.search',
          params: params,
        );
        if (run.ok) result = facultySearchFromDynamic(run.data);
      }
    } catch (_) {
      // Display a fixed failure, never a raw exception or source response.
    }
    if (!mounted || requestId != _requestId || _invalidated) return;
    if (_generation != _session?.trustedScriptViewGeneration ||
        _schoolId != _session?.selectedSchool?.id) {
      setState(() {
        _invalidated = true;
        _loading = false;
        _result = null;
        _submitted = null;
      });
      return;
    }
    if (result?.page != params['page'] ||
        result?.pageSize != params['pageSize']) {
      result = null;
    }
    setState(() {
      _loading = false;
      _failed = result == null;
      _result = result;
    });
  }

  Future<void> _copyProfile(String url) async {
    if (_invalidated) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted || _invalidated) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).commonLinkCopied)),
    );
  }

  @override
  void dispose() {
    _requestId++;
    _name.dispose();
    _researchArea.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final result = _result;
    return SectionCard(
      title: l10n.facultyTitle,
      summary: Text(l10n.facultyHint),
      child: _invalidated
          ? Text(l10n.homeCardDataChanged)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const Key('faculty-name'),
                  controller: _name,
                  enabled: !_loading,
                  maxLength: 80,
                  decoration: InputDecoration(
                    labelText: l10n.facultyName,
                    counterText: '',
                  ),
                  textInputAction: TextInputAction.search,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('faculty-research-area'),
                  controller: _researchArea,
                  enabled: !_loading,
                  maxLength: 80,
                  decoration: InputDecoration(
                    labelText: l10n.facultyDirection,
                    counterText: '',
                  ),
                  textInputAction: TextInputAction.search,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FilledButton.icon(
                    key: const Key('faculty-search'),
                    onPressed: _canSearch ? _submit : null,
                    icon: const Icon(Icons.search),
                    label: Text(l10n.facultySearch),
                  ),
                ),
                const SizedBox(height: 12),
                if (_loading)
                  const LinearProgressIndicator()
                else if (_failed) ...[
                  Text(l10n.facultyFailed),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(
                      onPressed: () => _load(_submitted!),
                      child: Text(l10n.commonRetry),
                    ),
                  ),
                ] else if (result == null)
                  Text(l10n.facultyHint)
                else ...[
                  Text(
                    l10n.facultySource(Uri.parse(result.sourceUrl).host),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (result.total != null)
                    Text(l10n.facultyResultCount(result.total!)),
                  const SizedBox(height: 8),
                  if (result.items.isEmpty) Text(l10n.facultyEmpty),
                  for (final item in result.items)
                    ExpansionTile(
                      key: ValueKey('faculty-$_requestId-${item.id}'),
                      tilePadding: EdgeInsets.zero,
                      title: Text(item.name),
                      subtitle: Text(
                        [
                          item.title,
                          item.department,
                        ].whereType<String>().join(' · '),
                      ),
                      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (item.disciplines?.isNotEmpty == true)
                          Text(item.disciplines!.join(' · ')),
                        if (item.researchAreas?.isNotEmpty == true)
                          Text(item.researchAreas!.join(' · ')),
                        const SizedBox(height: 8),
                        SelectableText(item.summary ?? l10n.facultyNoSummary),
                        if (item.profileUrl != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            l10n.facultyProfile,
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                          SelectableText(item.profileUrl!),
                          Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: TextButton.icon(
                              onPressed: () => _copyProfile(item.profileUrl!),
                              icon: const Icon(Icons.copy_outlined),
                              label: Text(l10n.commonCopyLink),
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                      ],
                    ),
                  const SizedBox(height: 8),
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      TextButton(
                        key: const Key('faculty-previous'),
                        onPressed: result.page > 1
                            ? () => _load({
                                ..._submitted!,
                                'page': result.page - 1,
                              })
                            : null,
                        child: Text(l10n.facultyPrevious),
                      ),
                      Text(l10n.facultyPage(result.page)),
                      TextButton(
                        key: const Key('faculty-next'),
                        onPressed: result.hasMore && result.page < 1000
                            ? () => _load({
                                ..._submitted!,
                                'page': result.page + 1,
                              })
                            : null,
                        child: Text(l10n.facultyNext),
                      ),
                    ],
                  ),
                ],
              ],
            ),
    );
  }
}
