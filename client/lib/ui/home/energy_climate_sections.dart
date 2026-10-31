/// Fixed schema renderers and foreground controls (ADR-004 §2 / ADR-040).
library;

import 'dart:async';
import 'package:flutter/material.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import '../../session/session_scope.dart';
import 'display_date.dart';
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

class _EnergySectionState extends State<EnergySection> {
  SessionController? _session;
  int? _generation;
  int _request = 0;
  List<Map<String, dynamic>>? _meters, _history;
  String? _selected;
  DateTime? _fetchedAt, _historyAt;
  DateTimeRange? _range;
  bool _busy = false, _failed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = SessionScope.of(context);
    if (_session != session ||
        _generation != session.trustedScriptViewGeneration) {
      _session = session;
      _generation = session.trustedScriptViewGeneration;
      _request++;
      _meters = null;
      _history = null;
      _selected = null;
      _range = null;
      _fetchedAt = null;
      _historyAt = null;
      _busy = false;
      _failed = false;
      _restore();
    }
  }

  bool _current(int request) =>
      mounted &&
      request == _request &&
      _session?.trustedScriptViewGeneration == _generation;
  Future<void> _restore() async {
    final request = _request;
    final cached = await _session!.cachedCapability('energy.meters');
    if (!_current(request) || cached == null) return;
    final history = await _session!.latestCachedCapability('energy.usage');
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

  Future<void> _load({bool history = false}) async {
    if (_busy) return;
    final request = ++_request;
    final selected = _selected;
    setState(() {
      _busy = true;
      _failed = false;
    });
    final params = <String, dynamic>{
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
      final result = await _session!.runCapability(capability, params: params);
      if (!_current(request)) return;
      if (!result.ok) {
        setState(() => _failed = true);
        return;
      }
      final cached = await _session!.cachedCapability(
        capability,
        params: params,
      );
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final meter = _meters?.where((m) => m['meterId'] == _selected).firstOrNull;
    return SectionCard(
      title: l10n.energyTitle,
      subtitle: l10n.energyPrompt,
      summary: CardSummary(
        meter?['remaining'] != null
            ? '${meter!['remaining']} ${meter['unit']}'
            : _busy
            ? l10n.homeCardLoading
            : _failed
            ? l10n.campusLoadFailed
            : _meters?.isEmpty == true
            ? l10n.energyEmpty
            : l10n.energyPrompt,
        detail: [
          if (_failed && meter?['remaining'] != null) l10n.campusLoadFailed,
          if (meter?['label'] is String) meter!['label'] as String,
          if (_fetchedAt != null)
            l10n.homeDataUpdatedAt(formatLocalDateTime(_fetchedAt!)),
        ].join(' · '),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_failed) Text(l10n.campusLoadFailed),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonal(
                onPressed: _busy ? null : () => _load(),
                child: Text(l10n.energyLoad),
              ),
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
                  : (value) => setState(() {
                      _selected = value;
                      _history = null;
                      _historyAt = null;
                    }),
            ),
            if (meter?['remaining'] != null)
              _DataLine(
                l10n.energyRemaining,
                '${meter!['remaining']} ${meter['unit']}',
              ),
            if (meter?['lastReadDate'] != null)
              _DataLine(l10n.energyReadDate, meter!['lastReadDate'] as String),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.tonal(
                onPressed: _busy || meter == null
                    ? null
                    : () => _load(history: true),
                child: Text(l10n.energyHistory),
              ),
            ),
          ],
          if (_fetchedAt != null)
            Text(
              l10n.homeDataUpdatedAt(formatLocalDateTime(_fetchedAt!)),
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
              l10n.homeDataUpdatedAt(formatLocalDateTime(_historyAt!)),
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
  SessionController? _session;
  int? _generation;
  int _request = 0, _actionEpoch = 0;
  List<Map<String, dynamic>> _devices = [];
  Map<String, dynamic>? _status;
  String? _selected, _outcome;
  bool _busy = false, _failed = false, _acting = false;
  BuildContext? _confirmation;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _actionEpoch++;
    _closeConfirmation();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _closeConfirmation() {
    final dialog = _confirmation;
    _confirmation = null;
    if (dialog != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (dialog.mounted && (ModalRoute.of(dialog)?.isCurrent ?? false)) {
          Navigator.of(dialog).pop(false);
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _actionEpoch++;
      final dialog = _confirmation;
      if (dialog != null && dialog.mounted) Navigator.of(dialog).pop(false);
      if (mounted) setState(() => _status = null);
    } else if (_selected != null && !_acting) {
      unawaited(_load(statusOnly: true));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = SessionScope.of(context);
    if (_session != session ||
        _generation != session.trustedScriptViewGeneration) {
      _closeConfirmation();
      _actionEpoch++;
      _request++;
      _session = session;
      _generation = session.trustedScriptViewGeneration;
      _devices = [];
      _status = null;
      _selected = null;
      _outcome = null;
      _busy = false;
      _acting = false;
      _failed = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_load(interactive: false));
      });
    }
  }

  bool _current(int request) =>
      mounted &&
      request == _request &&
      _session?.trustedScriptViewGeneration == _generation;
  Future<void> _load({
    bool statusOnly = false,
    bool configure = false,
    bool interactive = true,
  }) async {
    if (_busy || _acting) return;
    final request = ++_request;
    setState(() {
      _busy = true;
      _failed = false;
      _status = null;
    });
    try {
      if (!statusOnly) {
        final result = await _session!.runCapability(
          'climate.devices',
          params: {if (configure) 'configure': true},
          interactive: interactive,
        );
        if (!_current(request)) return;
        if (!result.ok) {
          if (interactive) setState(() => _failed = true);
          return;
        }
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
      final result = await _session!.runCapability(
        'climate.status',
        params: {'deviceId': _selected},
        interactive: false,
      );
      if (!_current(request)) return;
      setState(() {
        _status = result.ok ? _map(result.data) : null;
        if (_status?['deviceId'] != _selected) _status = null;
        _failed = _status == null;
      });
    } catch (_) {
      if (_current(request)) setState(() => _failed = true);
    } finally {
      if (_current(request)) setState(() => _busy = false);
    }
  }

  Future<void> _command(String command, Object value) async {
    if (_busy || _acting || _status == null || _selected == null) return;
    final epoch = ++_actionEpoch, generation = _generation;
    bool current() =>
        mounted &&
        epoch == _actionEpoch &&
        generation == _session?.trustedScriptViewGeneration &&
        (ModalRoute.of(context)?.isCurrent ?? false) &&
        (WidgetsBinding.instance.lifecycleState == null ||
            WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed);
    setState(() {
      _acting = true;
      _outcome = null;
    });
    try {
      final request = await _session!.prepareClimateCommand(
        _selected!,
        command,
        value,
      );
      if (!current()) return;
      final result = await _session!.runClimateCommand(
        request,
        isCurrent: current,
        confirm: (request) async {
          if (!current()) return false;
          final l10n = AppLocalizations.of(context);
          try {
            return await showDialog<bool>(
                  context: context,
                  builder: (dialog) {
                    _confirmation = dialog;
                    return AlertDialog(
                      title: Text(l10n.climateConfirmTitle),
                      content: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(request.packageName),
                            Text(
                              '${request.deviceLabel} · ${request.maskedDevice}',
                            ),
                            const SizedBox(height: 12),
                            Text(l10n.climateConfirmBody),
                            for (final entry in request.settings.entries)
                              _DataLine(
                                _settingLabel(l10n, entry.key),
                                _settingValue(l10n, entry.key, entry.value),
                              ),
                          ],
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialog, false),
                          child: Text(l10n.commonCancel),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(dialog, true),
                          child: Text(l10n.climateConfirmSend),
                        ),
                      ],
                    );
                  },
                ) ??
                false;
          } finally {
            _confirmation = null;
          }
        },
      );
      if (!current()) return;
      setState(() {
        _outcome = result.status;
        if (result.observed != null || result.status != 'rejected') {
          _status = result.observed?.ok == true
              ? _map(result.observed!.data)
              : null;
        }
      });
    } catch (_) {
      if (current()) {
        setState(() {
          _outcome = 'rejected';
          _status = null;
        });
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _acting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final device = _devices
        .where((d) => d['deviceId'] == _selected)
        .firstOrNull;
    final known =
        _status?['power'] is bool &&
        _status?['mode'] is String &&
        _status?['fanSpeed'] is String &&
        _status?['targetTemperature'] is int;
    final enabled =
        known &&
        climateControlAvailable &&
        !_busy &&
        !_acting &&
        _status != null &&
        _status!['online'] != false &&
        _status!['errorCode'] == null;
    return SectionCard(
      title: l10n.climateTitle,
      subtitle: l10n.climatePrompt,
      summary: CardSummary(
        _busy || _acting
            ? l10n.homeCardLoading
            : _failed
            ? l10n.campusLoadFailed
            : !known
            ? l10n.climateUnknown
            : '${_status!['targetTemperature']} ℃',
        detail: [
          if (device?['label'] is String) device!['label'] as String,
          if (_status?['power'] is bool)
            _status!['power'] == true ? l10n.climateOn : l10n.climateOff,
          if (_status?['observedAt'] is String)
            formatLocalDateTime(
              DateTime.parse(_status!['observedAt'] as String),
            ),
        ].join(' · '),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_busy || _acting) const LinearProgressIndicator(),
          if (_failed) Text(l10n.campusLoadFailed),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonal(
                onPressed: _busy || _acting ? null : () => _load(),
                child: Text(l10n.climateLoad),
              ),
              if (_selected != null)
                OutlinedButton(
                  onPressed: _busy || _acting
                      ? null
                      : () => _load(statusOnly: true),
                  child: Text(l10n.climateRefresh),
                ),
              if (_devices.isNotEmpty)
                TextButton(
                  onPressed: _busy || _acting
                      ? null
                      : () => _load(configure: true),
                  child: Text(l10n.climateConfigure),
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
                      setState(() => _selected = value);
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
          if (_status?['indoorTemperature'] != null)
            _DataLine(l10n.climateIndoor, '${_status!['indoorTemperature']} ℃'),
          if (device != null) ...[
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
                        onChanged: enabled
                            ? (value) => _command(key, value)
                            : null,
                      )
                    : _DataLine(_settingLabel(l10n, key), '—'),
            if ((device['commands'] as List).contains('temperature'))
              OverflowBar(
                alignment: MainAxisAlignment.spaceBetween,
                spacing: 8,
                children: [
                  Text(
                    '${l10n.climateTemperature}: ${_status?['targetTemperature'] ?? '—'} ℃',
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: l10n.climateDecreaseTemperature,
                        onPressed:
                            enabled &&
                                _status?['targetTemperature'] is int &&
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
                                _status?['targetTemperature'] is int &&
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
                            (device[itemsKey] as List).contains(_status?[key])
                            ? _status![key] as String
                            : null,
                        isExpanded: true,
                        itemHeight: null,
                        items: [
                          for (final value in device[itemsKey] as List)
                            DropdownMenuItem(
                              value: value as String,
                              child: Text(_settingValue(l10n, key, value)),
                            ),
                        ],
                        onChanged: enabled
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
