/// ADR-025 §2.2: bounded notice detail view; school requests stay in capabilities.
library;

import 'package:elecon_contract/notice_detail.dart';
import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import '../../session/session_scope.dart';
import 'display_date.dart';
import 'models.dart';
import 'capability_source.dart';

typedef NoticeDetailLoader = Future<NoticeDetail?> Function();

class NoticeDetailPage extends StatefulWidget {
  const NoticeDetailPage({
    required this.item,
    this.loadDetail,
    this.source,
    super.key,
  });

  final NoticeListItems item;
  final CapabilitySource? source;
  final NoticeDetailLoader? loadDetail;

  @override
  State<NoticeDetailPage> createState() => _NoticeDetailPageState();
}

class _NoticeDetailPageState extends State<NoticeDetailPage> {
  SessionController? _session;
  NoticeDetail? _detail;
  bool _bound = false, _loading = false, _failed = false;
  bool _invalidated = false;
  int _requestId = 0;
  int? _generation;
  String? _schoolId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = context
        .dependOnInheritedWidgetOfExactType<SessionScope>()
        ?.notifier;
    if (_bound) {
      if (!identical(_session, session) ||
          _schoolId != session?.selectedSchool?.id ||
          _generation != session?.trustedScriptViewGeneration) {
        // ADR-034 §3 / ADR-038 §2: an open detail belongs to its original
        // identity and approved installation, including already-rendered data.
        _requestId++;
        _detail = null;
        _loading = false;
        _failed = true;
        _invalidated = true;
      }
      return;
    }
    _bound = true;
    _session = session;
    _schoolId = session?.selectedSchool?.id;
    _generation = session?.trustedScriptViewGeneration;
    if ((widget.item.content?.trim().isEmpty ?? true) &&
        (widget.loadDetail != null || session != null)) {
      _loading = true;
      _load();
    }
  }

  Future<void> _load() async {
    if (_invalidated || _session?.selectedSchool?.id != _schoolId) return;
    final requestId = ++_requestId;
    final generation = _session?.trustedScriptViewGeneration;
    NoticeDetail? detail;
    try {
      if (widget.loadDetail != null) {
        detail = await widget.loadDetail!();
      } else {
        final source = widget.source;
        if (source != null) {
          final installation = (await _session!.scriptRegistry).find(
            source.packageId,
          );
          final package = installation?.package;
          if (installation?.enabled != true ||
              package == null ||
              package.requiresUpdate ||
              package.digest != source.digest ||
              package.manifest.schoolId != _schoolId) {
            throw const FormatException('notice_source_unavailable');
          }
          if (package.manifest.capability('notice.detail') == null) {
            // A valid list-only source may provide title/attachments without text.
            // Missing detail capability is an empty body, never a fallback source.
            if (mounted &&
                requestId == _requestId &&
                generation == _session?.trustedScriptViewGeneration) {
              setState(() {
                _loading = false;
                _failed = false;
              });
            }
            return;
          }
        }
        final run = await CapabilityQueries(_session!, source: widget.source)
            .runCapability(
              'notice.detail',
              params: {
                'id': widget.item.id,
                if (widget.item.url != null) 'url': widget.item.url,
              },
            );
        if (run.ok && run.data is Map) {
          final raw = run.data as Map;
          if (raw['id'] == widget.item.id && raw['title'] is String) {
            final attachments = <NoticeDetailAttachments>[];
            if (raw['attachments'] is List) {
              for (final value in raw['attachments'] as List) {
                if (value is Map &&
                    value['name'] is String &&
                    value['url'] is String) {
                  attachments.add(
                    NoticeDetailAttachments(
                      name: value['name'] as String,
                      url: value['url'] as String,
                    ),
                  );
                }
              }
            }
            detail = NoticeDetail(
              id: raw['id'] as String,
              title: raw['title'] as String,
              content: raw['content'] as String?,
              attachments: attachments,
            );
          }
        }
      }
    } catch (_) {
      // ADR-025 §2.7: never echo a school URL or raw exception to the user.
    }
    if (!mounted || requestId != _requestId) return;
    if (generation != _session?.trustedScriptViewGeneration) detail = null;
    setState(() {
      _loading = false;
      _failed = detail == null || detail.id != widget.item.id;
      _detail = _failed ? null : detail;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_invalidated) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.noticeDetailTitle)),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.noticeDetailFailed),
              const SizedBox(height: 8),
              FilledButton.tonal(
                onPressed: null,
                child: Text(l10n.noticeDetailRetry),
              ),
            ],
          ),
        ),
      );
    }
    final theme = Theme.of(context);
    final item = widget.item;
    final content = _detail?.content ?? item.content;
    final published = item.publishedAtDateTime;
    final meta =
        [
              item.source,
              if (item.author != null) item.author!,
              if (item.department != null) item.department!,
              if (published != null) formatLocalDate(published),
            ]
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .join(' · ');
    final attachments =
        _detail?.attachments ??
        [
          for (final value
              in item.attachments ?? const <NoticeListItemsAttachments>[])
            NoticeDetailAttachments(name: value.name, url: value.url),
        ];
    return Scaffold(
      appBar: AppBar(title: Text(l10n.noticeDetailTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            _detail?.title ?? item.title,
            style: theme.textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            meta,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const Divider(height: 24),
          if (_loading) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Text(l10n.noticeDetailLoading),
          ] else if (_failed) ...[
            Text(l10n.noticeDetailFailed),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonal(
                onPressed: _session?.selectedSchool?.id != _schoolId
                    ? null
                    : () {
                        setState(() {
                          _loading = true;
                          _failed = false;
                        });
                        _load();
                      },
                child: Text(l10n.noticeDetailRetry),
              ),
            ),
          ] else
            SelectableText(
              content?.trim().isNotEmpty == true
                  ? content!
                  : l10n.noticeDetailEmpty,
              style: theme.textTheme.bodyMedium,
            ),
          if (attachments.isNotEmpty) ...[
            const Divider(height: 24),
            Text(l10n.noticeAttachments, style: theme.textTheme.titleSmall),
            for (final attachment in attachments)
              // ADR-025 §2.7: external attachment opening needs separate isolation.
              ListTile(
                enabled: false,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.attach_file),
                title: Text(attachment.name),
              ),
          ],
        ],
      ),
    );
  }
}
