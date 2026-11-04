/// Native classroom selection and availability queries. Shared lifecycle lives in query_section.dart.
library;

import 'capability_source.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import '../../session/session_scope.dart';
import 'card_layout.dart';
import 'models.dart';
import 'schema_decode.dart';
import 'section_card.dart';
import 'classroom_timeline.dart';

import 'query_section.dart';
import 'script_query_controls.dart';

class ClassroomSection extends StatefulWidget {
  const ClassroomSection({super.key});

  @override
  State<ClassroomSection> createState() => _ClassroomSectionState();
}

class _ClassroomSectionState extends State<ClassroomSection>
    with CachedQuerySection<ClassroomSection, ClassroomAvailable> {
  bool _manualSelection = false;
  bool _prepared = false;
  String _room = "";
  String? _schemaVersion;
  Map<String, dynamic> _scriptParams = {};
  bool _filtersLoading = false;
  String? _filterError;
  @override
  void onConfigurationRequired() => _availPhase = QueryPhase.needConfiguration;

  @override
  String get cacheCapability => 'classroom.available';
  @override
  ClassroomAvailable? decodeCache(Object? value) =>
      classroomAvailableFromDynamic(value, schemaVersion: _schemaVersion);
  @override
  bool get useLatestCache => !_manualSelection;
  @override
  Map<String, dynamic>? get cacheParams => {
    ..._scriptParams,
    'date': formatQueryDate(_date),
    if (_selected?.buildingId != null) 'buildingId': _selected!.buildingId,
    if (_selected != null) 'building': _selected!.building,
    if (_selected?.campus != null) 'campus': _selected!.campus,
  };
  @override
  void applyCache(ClassroomAvailable data) {
    _scriptParams = {
      for (final key in ['room', 'start', 'end'])
        if (restoredParams[key] != null) key: restoredParams[key],
    };
    _avail = data;
    _availPhase = QueryPhase.loaded;
    _date =
        DateTime.tryParse(
          data.date ?? restoredParams['date']?.toString() ?? '',
        ) ??
        _date;
  }

  @override
  void clearCache() {
    _prepared = false;
    _room = "";
    _schemaVersion = null;
    _scriptParams = {};
    _filtersLoading = false;
    _filterError = null;
    _buildingsPhase = QueryPhase.idle;
    _buildings = const [];
    _selected = null;
    _avail = null;
    _availPhase = QueryPhase.idle;
    _date = DateTime.now();
    _manualSelection = false;
  }

  @override
  Future<void> restoreCache() async {
    final pendingSession = cacheSession;
    if (pendingSession == null) return;
    final pendingGeneration = pendingSession.trustedScriptViewGeneration;
    final pendingSource = CapabilitySourceScope.maybeOf(context)?.source;
    final version = await CapabilityQueries(
      pendingSession,
      source: pendingSource,
    ).schemaVersion(cacheCapability);
    if (!isCurrentQuery(
      this,
      pendingSession,
      pendingGeneration,
      pendingSource,
    )) {
      return;
    }
    _schemaVersion = version;
    await super.restoreCache();
    if (!mounted) return;
    final session = cacheSession;
    if (session == null) return;
    final read = cacheRead;
    final generation = session.trustedScriptViewGeneration;
    final source = CapabilitySourceScope.maybeOf(context)?.source;
    final cached = await CapabilitySourceScope.queriesOf(
      context,
      session,
    ).cachedCapability('classroom.buildings');
    if (!isCurrentQuery(this, session, generation, source) ||
        read != cacheRead ||
        cached == null) {
      return;
    }
    final decoded = classroomBuildingsFromDynamic(cached.data);
    if (decoded == null) return;
    setState(() {
      _buildings = decoded.items ?? const [];
      _buildingsPhase = _buildings.isEmpty
          ? QueryPhase.error
          : QueryPhase.loaded;
      if (_buildings.isEmpty) {
        _buildingsError = AppLocalizations.of(context).classroomNoBuildings;
      }
      if (_selected != null) {
        final selected = _selected!;
        _selected = _buildings
            .where(
              (item) => selected.buildingId != null
                  ? item.buildingId == selected.buildingId
                  : item.building == selected.building,
            )
            .firstOrNull;
      }
      if (_selected == null) {
        final matches = _buildings.where(
          (item) =>
              item.buildingId == restoredParams['buildingId'] &&
                  item.buildingId != null ||
              item.building == restoredParams['building'],
        );
        _selected = matches.firstOrNull ?? _buildings.firstOrNull;
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_prepared &&
        (HomeCardPresentation.maybeOf(context)?.isPage ?? false)) {
      _prepared = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await restoreCache();
        if (mounted && _buildingsPhase == QueryPhase.idle) {
          await _loadBuildings();
        }
      });
    }
  }

  // 教学楼列表阶段
  QueryPhase _buildingsPhase = QueryPhase.idle;
  List<ClassroomBuildingsItems> _buildings = const [];
  String? _buildingsError;
  ClassroomBuildingsItems? _selected;

  // 空教室查询阶段
  QueryPhase _availPhase = QueryPhase.idle;
  DateTime _date = DateTime.now();
  ClassroomAvailable? _avail;
  String? _availError;

  Future<void> _loadBuildings({bool configure = false}) async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final source = CapabilitySourceScope.maybeOf(context)?.source;
    setState(() => _buildingsPhase = QueryPhase.loading);
    final outcome = await runDecoded<ClassroomBuildings>(
      context,
      session,
      'classroom.buildings',
      params: {if (configure) 'configure': true},
      decode: classroomBuildingsFromDynamic,
    );
    if (!mounted || !isCurrentQuery(this, session, generation, source)) return;
    setState(() {
      if (outcome.needConfiguration) {
        _buildingsPhase = QueryPhase.needConfiguration;
      } else if (outcome.needLogin) {
        _buildingsPhase = QueryPhase.needLogin;
      } else if (outcome.error != null) {
        _buildingsPhase = QueryPhase.error;
        _buildingsError = outcome.error;
      } else {
        _buildingsPhase = QueryPhase.loaded;
        _buildings = outcome.data?.items ?? const [];
        if (_buildings.isEmpty) {
          _buildingsPhase = QueryPhase.error;
          _buildingsError = AppLocalizations.of(context).classroomNoBuildings;
        }
        _selected = _buildings.isNotEmpty ? _buildings.first : null;
      }
    });
  }

  Future<void> _loginThenBuildings() async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final source = CapabilitySourceScope.maybeOf(context)?.source;
    final ok = await promptVisibleLogin(
      context,
      session,
      capability: 'classroom.available',
    );
    if (!mounted || !isCurrentQuery(this, session, generation, source)) return;
    if (ok) await _loadBuildings();
  }

  Future<void> _loadAvailable({bool configure = false}) async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final source = CapabilitySourceScope.maybeOf(context)?.source;
    final building = _selected;
    if (building == null) return;
    setState(() => _availPhase = QueryPhase.loading);
    final version = await CapabilityQueries(
      session,
      source: source,
    ).schemaVersion(cacheCapability);
    if (!mounted || !isCurrentQuery(this, session, generation, source)) return;
    final params = <String, dynamic>{
      ..._scriptParams,
      'date': formatQueryDate(_date),
      if (configure) 'configure': true,
    };
    if (building.buildingId != null && building.buildingId!.isNotEmpty) {
      params['buildingId'] = building.buildingId;
      params['building'] = building.building;
      if (building.campus != null) params['campus'] = building.campus;
    } else {
      params['building'] = building.building;
    }
    final outcome = await runDecoded<ClassroomAvailable>(
      context,
      session,
      'classroom.available',
      params: params,
      decode: (raw) =>
          classroomAvailableFromDynamic(raw, schemaVersion: version),
    );
    if (!mounted || !isCurrentQuery(this, session, generation, source)) return;
    setState(() {
      if (outcome.needConfiguration) {
        _availPhase = QueryPhase.needConfiguration;
      } else if (outcome.needLogin) {
        _availPhase = QueryPhase.needLogin;
      } else if (outcome.error != null) {
        _availPhase = QueryPhase.error;
        _availError = outcome.error;
      } else {
        _availPhase = QueryPhase.loaded;
        _avail = outcome.data;
      }
    });
  }

  Future<void> _pickFilters() async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final source = CapabilitySourceScope.maybeOf(context)?.source;
    setState(() {
      _filtersLoading = true;
      _filterError = null;
    });
    try {
      final selection = await pickScriptQueryControls(
        context,
        session,
        'classroom.available',
        current: cacheParams,
      );
      if (!mounted || !isCurrentQuery(this, session, generation, source)) {
        return;
      }
      setState(() => _filtersLoading = false);
      if (!selection.supported) {
        await _pickDate();
        return;
      }
      if (selection.params == null) return;
      setState(() {
        _scriptParams = Map.of(selection.params!)..remove('date');
        _date =
            DateTime.tryParse(selection.params!['date']?.toString() ?? '') ??
            _date;
        _manualSelection = true;
        _avail = null;
        cacheRead++;
        cacheFetchedAt = null;
      });
      await _loadAvailable();
    } catch (_) {
      if (mounted && isCurrentQuery(this, session, generation, source)) {
        setState(() {
          _filtersLoading = false;
          _filterError = AppLocalizations.of(
            context,
          ).scriptsSourceResponseInvalid;
        });
      }
    }
  }

  Future<void> _pickDate() async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final source = CapabilitySourceScope.maybeOf(context)?.source;
    final now = DateTime.now();
    final first = DateUtils.dateOnly(now.subtract(const Duration(days: 30)));
    final last = DateUtils.dateOnly(now.add(const Duration(days: 180)));
    final initial = _date.isBefore(first)
        ? first
        : _date.isAfter(last)
        ? last
        : _date;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
    );
    if (picked != null && isCurrentQuery(this, session, generation, source)) {
      setState(() {
        _date = picked;
        _manualSelection = true;
        _avail = null;
        cacheFetchedAt = null;
        _availPhase = QueryPhase.idle;
      });
      unawaited(restoreCache());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (HomeCardPresentation.isPreview(context) && _avail != null) {
      return withCacheTime(
        _ClassroomResultCard(
          data: _avail!,
          trailing: SectionRefreshButton(
            onPressed:
                _availPhase == QueryPhase.loading ||
                    _buildingsPhase == QueryPhase.loading
                ? null
                : () async {
                    if (_selected == null) await _loadBuildings();
                    if (mounted && _selected != null) await _loadAvailable();
                  },
          ),
        ),
      );
    }
    // 教学楼未就绪：先引导取列表（可能触发登录）。
    if (_buildingsPhase != QueryPhase.loaded) {
      return Column(
        children: [
          QueryPromptCard(
            title: '空教室',
            trailing: SectionRefreshButton(
              onPressed: _buildingsPhase == QueryPhase.loading
                  ? null
                  : _loadBuildings,
            ),
            summary: querySummary(context, _buildingsPhase),
            subtitle: AppLocalizations.of(context).classroomPreparing,
            child: QueryPhaseBody(
              phase: _buildingsPhase,
              error: _buildingsError,

              onLogin: _loginThenBuildings,
              onConfigure: () => _loadBuildings(configure: true),
            ),
          ),
          if (_avail != null)
            withCacheTime(_ClassroomResultCard(data: _avail!)),
        ],
      );
    }

    final busy = _availPhase == QueryPhase.loading;
    return Column(
      children: [
        QueryPromptCard(
          title: '空教室',
          trailing: SectionRefreshButton(
            onPressed: busy ? null : _loadAvailable,
          ),
          summary: querySummary(context, _availPhase),
          subtitle: AppLocalizations.of(context).classroomSearchHint,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButton<ClassroomBuildingsItems>(
                isExpanded: true,
                value: _selected,
                onChanged: busy
                    ? null
                    : (b) => setState(() {
                        _selected = b;
                        _manualSelection = true;
                        _avail = null;
                        cacheFetchedAt = null;
                        _availPhase = QueryPhase.idle;
                        unawaited(restoreCache());
                      }),
                items: [
                  for (final b in _buildings)
                    DropdownMenuItem(
                      value: b,
                      child: Text(
                        b.roomCount == null
                            ? b.building
                            : '${b.building}（${b.roomCount} 间）',
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(child: Text('日期：${formatQueryDate(_date)}')),
                  TextButton.icon(
                    onPressed: busy ? null : _pickDate,
                    icon: const Icon(Icons.calendar_today, size: 18),
                    label: const Text('选择日期'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: busy || _filtersLoading ? null : _pickFilters,
                icon: const Icon(Icons.filter_list),
                label: Text(AppLocalizations.of(context).queryFilters),
              ),
              if (_filterError != null) Text(_filterError!),
              QueryPhaseBody(
                phase: _availPhase,
                error: _availError,
                onConfigure: () => _loadAvailable(configure: true),

                onLogin: () async {
                  final session = SessionScope.of(context);
                  final generation = session.trustedScriptViewGeneration;
                  final source = CapabilitySourceScope.maybeOf(context)?.source;
                  final ok = await promptVisibleLogin(
                    context,
                    session,
                    capability: 'classroom.available',
                  );
                  if (isCurrentQuery(this, session, generation, source) && ok) {
                    await _loadAvailable();
                  }
                },
              ),
            ],
          ),
        ),
        if (_avail != null) ...[
          TextField(
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              labelText: AppLocalizations.of(context).classroomRoomHint,
            ),
            onChanged: (value) => setState(() => _room = value.trim()),
          ),
          withCacheTime(_ClassroomResultCard(data: _avail!, roomFilter: _room)),
        ],
      ],
    );
  }
}

class _ClassroomResultCard extends StatelessWidget {
  const _ClassroomResultCard({
    required this.data,
    this.roomFilter = "",
    this.trailing,
  });
  final Widget? trailing;
  final String roomFilter;

  final ClassroomAvailable data;

  @override
  Widget build(BuildContext context) {
    final items = (data.items ?? const <ClassroomAvailableItems>[])
        .where((item) => item.room.contains(roomFilter))
        .toList();
    final free = items
        .where(
          (i) =>
              i.occupied == false ||
              (i.occupied == null && i.status == 'available'),
        )
        .toList();
    return SectionCard(
      title: '空教室',
      trailing: trailing,
      summary: CardSummary(
        '${free.length}/${items.length}',
        detail: [
          AppLocalizations.of(context).homeCardAvailableRooms,
          if (data.date != null) data.date!,
        ].join(' · '),
      ),
      subtitle: [
        if (data.date != null) data.date!,
        '${free.length}/${items.length} 空闲',
      ].join(' · '),
      child: items.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('该教学楼当日无可展示教室'),
            )
          : items.any((room) => room.intervals != null)
          ? ClassroomTimeline(
              key: ValueKey('${data.date}/${items.first.buildingId}'),
              rooms: items,
            )
          : Column(
              children: [
                for (final room in items)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      room.occupied == true
                          ? Icons.meeting_room
                          : Icons.meeting_room_outlined,
                      color: room.occupied == true
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.primary,
                    ),
                    title: Text('${room.building} ${room.room}'),
                    subtitle: Text(
                      [
                        if (room.floor != null) '${room.floor} 层',
                        if (room.capacity != null) '${room.capacity} 座',
                        if (room.status != null) _roomStatusText(room.status!),
                      ].join(' · '),
                    ),
                  ),
              ],
            ),
    );
  }
}

String _roomStatusText(String status) => switch (status) {
  'available' => '空闲',
  'occupied' => '占用',
  'partial' => '部分占用',
  _ => status,
};

// ===========================================================================
// 一卡通（用户按需；余额 → 交易明细）
// ===========================================================================
