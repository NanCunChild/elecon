/// Fixed schema renderers and foreground controls (ADR-004 §2 / ADR-040).
library;

import 'query_section.dart';

import 'capability_source.dart';

import 'dart:async';
import 'package:flutter/material.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import '../../session/session_scope.dart';
import 'display_date.dart';
import 'climate_controls.dart';
import 'section_card.dart';

Map<String, dynamic>? _map(Object? data) =>
    data is Map ? Map<String, dynamic>.from(data) : null;
List<Map<String, dynamic>> _items(Object? data) =>
    ((_map(data)?['items'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

class EnergySection extends StatefulWidget {
  const EnergySection({super.key});
  @override
  State<EnergySection> createState() => _EnergySectionState();
}

class _EnergySectionState extends State<EnergySection>
    with CachedQuerySection<EnergySection, Map<String, dynamic>> {
  SessionController? _session;
  CapabilitySource? _source;
  int? _generation;
  int _request = 0;
  List<Map<String, dynamic>>? _meters, _history;
  String? _selected;
  DateTime? _fetchedAt, _historyAt;
  DateTimeRange? _range;
  bool _busy = false, _failed = false, _needsConfiguration = false;

  @override
  String get cacheCapability => 'energy.meters';
  @override
  Map<String, dynamic>? decodeCache(Object? raw) =>
      raw is Map<String, dynamic> ? raw : null;
  @override
  void applyCache(Map<String, dynamic> data) {
    _meters = _items(data);
    _fetchedAt = cacheFetchedAt;
  }

  @override
  void onCacheRestored() => unawaited(_restore());
  @override
  void clearCache() {
    _session = cacheSession;
    _source = CapabilitySourceScope.maybeOf(context)?.source;
    _generation = _session?.trustedScriptViewGeneration;
    _request++;
    _meters = null;
    _history = null;
    _selected = null;
    _range = null;
    _fetchedAt = null;
    _historyAt = null;
    _busy = false;
    _failed = false;
    _needsConfiguration = false;
  }

  bool _current(int request) =>
      mounted &&
      request == _request &&
      _session?.trustedScriptViewGeneration == _generation;
  Future<void> _restore() async {
    final request = _request;
    final cached = await CapabilityQueries(
      _session!,
      source: _source,
    ).cachedCapability('energy.meters');
    if (!_current(request)) return;
    if (cached == null) {
      final needsConfiguration = await CapabilityQueries(
        _session!,
        source: _source,
      ).capabilityNeedsConfiguration('energy.meters');
      if (_current(request)) {
        setState(() => _needsConfiguration = needsConfiguration);
      }
      return;
    }
    final history = await CapabilityQueries(
      _session!,
      source: _source,
    ).latestCachedCapability('energy.usage');
    if (!_current(request)) return;
    setState(() {
      _meters = _items(cached.data);
      _fetchedAt = cached.fetchedAt;
      final previous = history?.params['meterId'];
      if (previous is String &&
          _meters!.any((meter) => meter['meterId'] == previous)) {
        _selected = previous;
        _history = _items(history!.data);
        _historyAt = history.fetchedAt;
        final from = DateTime.tryParse(
          history.params['from']?.toString() ?? '',
        )?.toLocal();
        final to = DateTime.tryParse(
          history.params['to']?.toString() ?? '',
        )?.toLocal();
        if (from != null && to != null) {
          _range = DateTimeRange(start: from, end: to);
        }
      }
    });
  }

  Future<void> _load({bool history = false, bool configure = false}) async {
    if (_busy) return;
    final request = ++_request;
    final selected = _selected;
    setState(() {
      _busy = true;
      _failed = false;
    });
    final params = <String, dynamic>{
      if (configure) 'configure': true,
      if (history && selected != null) 'meterId': selected,
    };
    if (history && _range != null) {
      // The standard contract carries instants; the school script maps these
      // to its own wall-clock API. This renderer contains no school timezone.
      final start = _range!.start, end = _range!.end;
      params['from'] = DateTime(
        start.year,
        start.month,
        start.day,
      ).toUtc().toIso8601String();
      params['to'] = DateTime(
        end.year,
        end.month,
        end.day,
        23,
        59,
        59,
      ).toUtc().toIso8601String();
    }
    try {
      final capability = history ? 'energy.usage' : 'energy.meters';
      final result = await CapabilityQueries(
        _session!,
        source: _source,
      ).runCapability(capability, params: params);
      if (!_current(request)) return;
      if (!result.ok) {
        setState(() {
          _needsConfiguration = result.reason == 'configuration_required';
          _failed = !_needsConfiguration;
        });
        return;
      }
      _needsConfiguration = false;
      final cached = await CapabilityQueries(
        _session!,
        source: _source,
      ).cachedCapability(capability, params: params);
      if (!_current(request)) return;
      setState(() {
        if (history) {
          _history = _items(result.data);
          _historyAt = cached?.fetchedAt;
        } else {
          _meters = _items(result.data);
          _fetchedAt = cached?.fetchedAt;
          if (!_meters!.any((m) => m['meterId'] == _selected)) {
            _selected = null;
            _history = null;
            _historyAt = null;
          }
        }
      });
    } catch (_) {
      if (_current(request)) setState(() => _failed = true);
    } finally {
      if (_current(request)) setState(() => _busy = false);
    }
  }

  Future<void> _refresh({bool configure = false}) async {
    final session = _session, generation = _generation;
    await _load(configure: configure);
    if (!mounted ||
        session != _session ||
        generation != _generation ||
        _needsConfiguration) {
      return;
    }
    if (mounted && !_failed && _selected != null) await _load(history: true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final meter = _meters?.where((m) => m['meterId'] == _selected).firstOrNull;
    return SectionCard(
      title: l10n.energyTitle,
      trailing: SectionRefreshButton(onPressed: _busy ? null : _refresh),
      subtitle: l10n.energyPrompt,
      summary: CardSummary(
        meter?['remaining'] != null
            ? '${meter!['remaining']} ${meter['unit']}'
            : _busy
            ? l10n.homeCardLoading
            : _needsConfiguration
            ? l10n.capabilityConfigurationRequired
            : _failed
            ? l10n.campusLoadFailed
            : _meters?.isEmpty == true
            ? l10n.energyEmpty
            : l10n.energyPrompt,
        detail: [
          if (_failed && meter?['remaining'] != null) l10n.campusLoadFailed,
          if (meter?['label'] is String) meter!['label'] as String,
          if (_fetchedAt != null)
            l10n.homeDataUpdatedAt(formatUpdateTime(_fetchedAt!, l10n)),
        ].join(' · '),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_failed) Text(l10n.campusLoadFailed),
          if (_needsConfiguration) Text(l10n.capabilityConfigurationRequired),
          if (_needsConfiguration)
            TextButton.icon(
              onPressed: _busy ? null : () => _refresh(configure: true),
              icon: const Icon(Icons.edit_outlined),
              label: Text(l10n.capabilityCompleteConfiguration),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () async {
                        final now = DateTime.now();
                        final range = await showDateRangePicker(
                          context: context,
                          firstDate: DateTime(now.year - 3),
                          lastDate: now,
                          initialDateRange: _range,
                        );
                        if (mounted && range != null) {
                          setState(() {
                            _range = range;
                            _history = null;
                            _historyAt = null;
                          });
                          if (_selected != null) await _load(history: true);
                        }
                      },
                child: Text(
                  _range == null
                      ? l10n.energyDates
                      : '${formatLocalDate(_range!.start)} – ${formatLocalDate(_range!.end)}',
                ),
              ),
            ],
          ),
          if (_meters?.isEmpty == true) Text(l10n.energyEmpty),
          if (_meters?.isNotEmpty == true) ...[
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _selected,
              key: ValueKey((
                _generation,
                _selected,
                _meters!.map((m) => m['meterId']).join('|'),
              )),
              isExpanded: true,
              decoration: InputDecoration(labelText: l10n.energyMeter),
              items: [
                for (final m in _meters!)
                  DropdownMenuItem(
                    value: m['meterId'] as String,
                    child: Text(
                      '${m['label'] ?? (m['type'] == 'water' ? l10n.energyWater : l10n.energyElectricity)} · ${m['meterId']}',
                    ),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (value) {
                      setState(() {
                        _selected = value;
                        _history = null;
                        _historyAt = null;
                      });
                      if (value != null) unawaited(_load(history: true));
                    },
            ),
            if (meter?['remaining'] != null)
              _DataLine(
                l10n.energyRemaining,
                '${meter!['remaining']} ${meter['unit']}',
              ),
            if (meter?['lastReadDate'] != null)
              _DataLine(l10n.energyReadDate, meter!['lastReadDate'] as String),
          ],
          if (_fetchedAt != null)
            Text(
              l10n.homeDataUpdatedAt(formatUpdateTime(_fetchedAt!, l10n)),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (_history?.isEmpty == true) Text(l10n.energyNoHistory),
          if (_history?.isNotEmpty == true)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: [
                  for (final label in [
                    l10n.energyReadAt,
                    l10n.energyUsage,
                    l10n.energyReading,
                    l10n.energyPrevious,
                  ])
                    DataColumn(label: Text(label)),
                ],
                rows: [
                  for (final row in _history!)
                    DataRow(
                      cells: [
                        DataCell(
                          Text(
                            row['readAt'] is String
                                ? formatLocalDateTime(
                                    DateTime.parse(row['readAt'] as String),
                                  )
                                : '—',
                          ),
                        ),
                        for (final key in [
                          'usage',
                          'reading',
                          'previousReading',
                        ])
                          DataCell(
                            Text(
                              row[key] == null
                                  ? '—'
                                  : '${row[key]} ${row['unit'] ?? ''}',
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          if (_historyAt != null)
            Text(
              l10n.homeDataUpdatedAt(formatUpdateTime(_historyAt!, l10n)),
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}

class ClimateSection extends StatefulWidget {
  const ClimateSection({super.key});
  @override
  State<ClimateSection> createState() => _ClimateSectionState();
}

class _ClimateSectionState extends State<ClimateSection>
    with WidgetsBindingObserver {
  ScriptRunCancellation _workCancellation = ScriptRunCancellation();
  bool _routeVisible = true;
  bool _foreground = true;
  SessionController? _session;
  CapabilitySource? _source;
  int? _generation;
  int? _dataGeneration;
  bool _statusCurrent = false;
  DateTime? _statusAt;
  int _request = 0, _actionEpoch = 0;
  List<Map<String, dynamic>> _devices = [];
  Map<String, dynamic>? _status;
  String? _selected, _outcome;
  bool _busy = false,
      _failed = false,
      _acting = false,
      _needsConfiguration = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _workCancellation.cancel();
    _actionEpoch++;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (state != AppLifecycleState.resumed) {
      _workCancellation.cancel();
      _request++;
      _actionEpoch++;
      if (mounted) {
        setState(() {
          _statusCurrent = false;
          _busy = false;
          _acting = false;
        });
      }
    } else if (_selected != null && _routeVisible) {
      _workCancellation = ScriptRunCancellation();
      unawaited(_load(statusOnly: true));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = SessionScope.of(context);
    final source = CapabilitySourceScope.maybeOf(context)?.source;
    final visible = ModalRoute.of(context)?.isCurrent ?? true;
    if (visible != _routeVisible) {
      _routeVisible = visible;
      _workCancellation.cancel();
      _workCancellation = ScriptRunCancellation();
      _request++;
      _actionEpoch++;
      _busy = false;
      _acting = false;
      _statusCurrent = false;
      if (visible) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_restoreThenLoad());
        });
      }
    }
    if (_source != source ||
        _session != session ||
        _generation != session.trustedScriptViewGeneration ||
        _dataGeneration != session.trustedScriptDataGeneration) {
      _workCancellation.cancel();
      _workCancellation = ScriptRunCancellation();
      _actionEpoch++;
      _request++;
      _session = session;
      _source = source;
      _generation = session.trustedScriptViewGeneration;
      _dataGeneration = session.trustedScriptDataGeneration;
      _statusCurrent = false;
      _statusAt = null;
      _devices = [];
      _status = null;
      _selected = null;
      _outcome = null;
      _busy = false;
      _acting = false;
      _failed = false;
      _needsConfiguration = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_restoreThenLoad());
      });
    }
  }

  bool _current(int request) =>
      mounted &&
      request == _request &&
      _session?.trustedScriptViewGeneration == _generation &&
      _session?.trustedScriptDataGeneration == _dataGeneration;
  Future<void> _restoreThenLoad() async {
    final request = _request;
    final queries = CapabilityQueries(_session!, source: _source);
    try {
      final devices = await queries.cachedCapability('climate.devices');
      final status = await queries.latestCachedCapability('climate.status');
      if (!_current(request)) return;
      if (devices != null) {
        final rows = _items(devices.data);
        final selected = status?.params['deviceId'];
        setState(() {
          _devices = rows;
          if (selected is String &&
              rows.any((row) => row['deviceId'] == selected)) {
            _selected = selected;
            _status = _map(status?.data);
            if (_status?['deviceId'] != selected) _status = null;
            _statusAt = status?.fetchedAt;
          }
          _statusCurrent = false;
        });
      }
    } catch (_) {
      /* Live read still has the ordinary error path. */
    }
    if (_current(request)) await _load(interactive: false);
  }

  Future<void> _load({
    bool statusOnly = false,
    bool configure = false,
    bool interactive = true,
  }) async {
    if (_busy || _acting || !_foreground || !_routeVisible) return;
    if (_workCancellation.isCancelled) {
      _workCancellation = ScriptRunCancellation();
    }
    final cancellation = _workCancellation;
    final request = ++_request;
    setState(() {
      _busy = true;
      _failed = false;
      _statusCurrent = false;
    });
    try {
      if (!statusOnly) {
        final result = await CapabilityQueries(_session!, source: _source)
            .runCapability(
              'climate.devices',
              cancellation: cancellation,
              params: {if (configure) 'configure': true},
              interactive: interactive,
            );
        if (!_current(request)) return;
        if (!result.ok) {
          setState(() {
            _needsConfiguration = result.reason == 'configuration_required';
            _failed = !_needsConfiguration;
          });
          return;
        }
        _needsConfiguration = false;
        final devices = _items(result.data);
        setState(() {
          _devices = devices;
          if (!devices.any((d) => d['deviceId'] == _selected)) {
            _selected = devices.length == 1
                ? devices.single['deviceId'] as String
                : null;
          }
        });
      }
      if (_selected == null) return;
      final result = await CapabilityQueries(_session!, source: _source)
          .runCapability(
            'climate.status',
            cancellation: cancellation,
            params: {'deviceId': _selected},
            interactive: false,
          );
      if (!_current(request)) return;
      setState(() {
        if (result.ok) {
          _status = _map(result.data);
          _statusAt = DateTime.now();
        }
        _statusCurrent = result.ok;
        if (_status?['deviceId'] != _selected) _status = null;
        _failed = !result.ok || _status == null;
      });
    } catch (_) {
      if (_current(request)) setState(() => _failed = true);
    } finally {
      if (_current(request)) setState(() => _busy = false);
    }
  }

  Future<void> _command(String command, Object value) async {
    if (_busy ||
        _acting ||
        (_status == null || !_statusCurrent) ||
        _selected == null ||
        !climateControlAvailable) {
      return;
    }
    final session = _session!;
    final cancellation = _workCancellation;
    final deviceId = _selected!;
    final device = _devices.where((d) => d['deviceId'] == deviceId).firstOrNull;
    if (device == null ||
        _status!['online'] == false ||
        _status!['errorCode'] != null ||
        !climateCommandReady(device, _status, command)) {
      return;
    }
    final epoch = ++_actionEpoch, generation = _generation;
    bool current() =>
        mounted &&
        identical(session, _session) &&
        epoch == _actionEpoch &&
        generation == session.trustedScriptViewGeneration &&
        (ModalRoute.of(context)?.isCurrent ?? false) &&
        (WidgetsBinding.instance.lifecycleState == null ||
            WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed);
    if (!current()) return;
    Map<String, dynamic> settings;
    try {
      settings = climateTarget(device, command, value);
    } on ClimateControlException {
      return;
    }
    setState(() {
      _acting = true;
      _outcome = null;
    });
    try {
      var outcome = 'unknown';
      try {
        final result = await CapabilityQueries(session, source: _source)
            .runCapability(
              'climate.command',
              cancellation: cancellation,
              params: {
                'deviceId': deviceId,
                'command': command,
                'settings': settings,
              },
              interactive: false,
            );
        outcome = climateCommandOutcome(ok: result.ok, output: result.data);
      } catch (_) {
        // A failed/uncertain send is never retried. Read the state once below.
      }
      if (!current()) return;
      Map<String, dynamic>? observed;
      try {
        final result = await CapabilityQueries(session, source: _source)
            .runCapability(
              'climate.status',
              cancellation: cancellation,
              params: {'deviceId': deviceId},
              interactive: false,
            );
        if (result.ok) observed = _map(result.data);
        if (observed?['deviceId'] != deviceId) observed = null;
      } catch (_) {
        // A failed state read cannot justify another command.
      }
      if (!current()) return;
      if ((outcome == 'accepted' || outcome == 'unknown') &&
          observed != null &&
          settings.entries.every((e) => observed![e.key] == e.value)) {
        outcome = 'applied';
      }
      setState(() {
        _outcome = outcome;
        _status = observed;
        _statusCurrent = observed != null;
        _statusAt = observed == null ? null : DateTime.now();
        _failed = observed == null;
      });
    } finally {
      if (mounted &&
          identical(session, _session) &&
          generation == _generation) {
        setState(() => _acting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final device = _devices
        .where((d) => d['deviceId'] == _selected)
        .firstOrNull;
    final known = _status != null;
    final enabled =
        climateControlAvailable &&
        !_busy &&
        !_acting &&
        _status != null &&
        _statusCurrent &&
        _status!['online'] != false &&
        _status!['errorCode'] == null;
    return SectionCard(
      title: l10n.climateTitle,
      trailing: SectionRefreshButton(
        onPressed: _busy || _acting ? null : () => _load(),
      ),
      subtitle: l10n.climatePrompt,
      summary: CardSummary(
        device?['label'] as String? ??
            (_busy || _acting
                ? l10n.homeCardLoading
                : _needsConfiguration
                ? l10n.capabilityConfigurationRequired
                : _failed
                ? l10n.campusLoadFailed
                : l10n.climateUnknown),
        detail: [
          '${l10n.climateTemperature}: ${_status?['targetTemperature'] ?? '—'} ℃',
          '${l10n.climateIndoor}: ${_status?['indoorTemperature'] ?? '—'} ℃',
          if (_status?['power'] is bool)
            _status!['power'] == true ? l10n.climateOn : l10n.climateOff,
          if (_status?['mode'] is String)
            _settingValue(l10n, 'mode', _status!['mode']),
          if (_failed) l10n.campusLoadFailed,
          if (_status?['observedAt'] is String)
            formatLocalDateTime(
              DateTime.parse(_status!['observedAt'] as String),
            ),
        ].join(' · '),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_statusAt != null && !_statusCurrent)
            Text(
              l10n.homeDataStaleAt(formatUpdateTime(_statusAt!, l10n)),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (_busy || _acting) const LinearProgressIndicator(),
          if (_failed) Text(l10n.campusLoadFailed),
          if (_needsConfiguration) Text(l10n.capabilityConfigurationRequired),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (_devices.isNotEmpty || _needsConfiguration)
                TextButton(
                  onPressed: _busy || _acting
                      ? null
                      : () => _load(configure: true),
                  child: Text(
                    _needsConfiguration
                        ? l10n.capabilityCompleteConfiguration
                        : l10n.climateConfigure,
                  ),
                ),
            ],
          ),
          if (_devices.isNotEmpty)
            DropdownButtonFormField<String>(
              key: ValueKey((_generation, _selected)),
              initialValue: _selected,
              isExpanded: true,
              items: [
                for (final d in _devices)
                  DropdownMenuItem(
                    value: d['deviceId'] as String,
                    child: Text(
                      '${d['label']} · ••••${(d['deviceId'] as String).length > 4 ? (d['deviceId'] as String).substring((d['deviceId'] as String).length - 4) : '••••'}',
                    ),
                  ),
              ],
              onChanged: _busy || _acting
                  ? null
                  : (value) {
                      setState(() {
                        _selected = value;
                        _status = null;
                        _statusAt = null;
                        _statusCurrent = false;
                      });
                      unawaited(_load(statusOnly: true));
                    },
            ),
          if (!climateControlAvailable) Text(l10n.climateReadOnly),
          if (_selected != null && !known) Text(l10n.climateUnknown),
          if (_outcome != null)
            Text(switch (_outcome) {
              'applied' => l10n.climateApplied,
              'accepted' => l10n.climateAccepted,
              'unknown' => l10n.climateUncertain,
              _ => l10n.climateRejected,
            }),
          if (_status?['errorCode'] != null) Text(l10n.climateError),
          if (_status?['observedAt'] is String)
            Text(
              formatLocalDateTime(
                DateTime.parse(_status!['observedAt'] as String),
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (device != null)
            _DataLine(
              l10n.climateIndoor,
              '${_status?['indoorTemperature'] ?? '—'} ℃',
            ),
          if (device != null) ...[
            if ((device['commands'] as List).contains('temperature'))
              OverflowBar(
                alignment: MainAxisAlignment.spaceBetween,
                spacing: 8,
                children: [
                  Text(
                    '${l10n.climateTemperature}: ${_status?['targetTemperature'] ?? '—'} ℃',
                    style: Theme.of(context).textTheme.headlineMedium,
                    textAlign: TextAlign.center,
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: l10n.climateDecreaseTemperature,
                        onPressed:
                            enabled &&
                                climateCommandReady(
                                  device,
                                  _status,
                                  'temperature',
                                ) &&
                                (_status!['targetTemperature'] as int) >
                                    (device['minTemperature'] as num)
                            ? () => _command(
                                'temperature',
                                (_status!['targetTemperature'] as int) - 1,
                              )
                            : null,
                        icon: const Icon(Icons.remove),
                      ),
                      IconButton(
                        tooltip: l10n.climateIncreaseTemperature,
                        onPressed:
                            enabled &&
                                climateCommandReady(
                                  device,
                                  _status,
                                  'temperature',
                                ) &&
                                (_status!['targetTemperature'] as int) <
                                    (device['maxTemperature'] as num)
                            ? () => _command(
                                'temperature',
                                (_status!['targetTemperature'] as int) + 1,
                              )
                            : null,
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                ],
              ),
            for (final key in [
              'power',
              'verticalSwing',
              'turbo',
              'auxiliaryHeat',
            ])
              if ((device['commands'] as List).contains(key))
                _status?[key] is bool
                    ? SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(_settingLabel(l10n, key)),
                        value: _status![key] as bool,
                        onChanged:
                            enabled && climateCommandReady(device, _status, key)
                            ? (value) => _command(key, value)
                            : null,
                      )
                    : _DataLine(_settingLabel(l10n, key), '—'),
            for (final (key, itemsKey) in [
              ('mode', 'modes'),
              ('fanSpeed', 'fanSpeeds'),
            ])
              if ((device['commands'] as List).contains(key))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: _settingLabel(l10n, key),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        key: ValueKey((key, _selected)),
                        value:
                            ((device[itemsKey] as List?) ?? const []).contains(
                              _status?[key],
                            )
                            ? _status![key] as String
                            : null,
                        isExpanded: true,
                        itemHeight: null,
                        items: [
                          for (final value
                              in (device[itemsKey] as List?) ?? const [])
                            DropdownMenuItem(
                              value: value as String,
                              child: Text(_settingValue(l10n, key, value)),
                            ),
                        ],
                        onChanged:
                            enabled && climateCommandReady(device, _status, key)
                            ? (value) {
                                if (value != null) {
                                  unawaited(_command(key, value));
                                }
                              }
                            : null,
                      ),
                    ),
                  ),
                ),
          ],
        ],
      ),
    );
  }
}

class _DataLine extends StatelessWidget {
  const _DataLine(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: OverflowBar(
      alignment: MainAxisAlignment.spaceBetween,
      spacing: 12,
      overflowSpacing: 4,
      children: [Text(label), Text(value)],
    ),
  );
}

String _settingLabel(AppLocalizations l10n, String key) => switch (key) {
  'power' => l10n.climatePower,
  'mode' => l10n.climateMode,
  'fanSpeed' => l10n.climateFan,
  'targetTemperature' => l10n.climateTemperature,
  'verticalSwing' => l10n.climateSwing,
  'turbo' => l10n.climateTurbo,
  'auxiliaryHeat' => l10n.climateAuxHeat,
  'indoorClean' => l10n.climateIndoorClean,
  'outdoorClean' => l10n.climateOutdoorClean,
  _ => l10n.climateUnknown,
};
String _settingValue(AppLocalizations l10n, String key, Object? value) {
  if (value is bool) return value ? l10n.climateOn : l10n.climateOff;
  if (key == 'targetTemperature') return '$value ℃';
  return switch (value) {
    'fan' => l10n.climateModeFan,
    'heat' => l10n.climateModeHeat,
    'cool' => l10n.climateModeCool,
    'dry' => l10n.climateModeDry,
    'auto' => l10n.climateModeAuto,
    'silent' => l10n.climateFanSilent,
    'low' => l10n.climateFanLow,
    'medium' => l10n.climateFanMedium,
    'high' => l10n.climateFanHigh,
    _ => l10n.climateUnknown,
  };
}
