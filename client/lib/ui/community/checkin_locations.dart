import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../core/scripts/manifest.dart';
import '../../session/session_controller.dart';

class CheckinLocations extends StatefulWidget {
  const CheckinLocations({
    super.key,
    required this.session,
    required this.package,
    required this.enabled,
    required this.onSelected,
  });
  final SessionController session;
  final ScriptPackage package;
  final bool enabled;
  final ValueChanged<AttendancePlace?> onSelected;
  @override
  State<CheckinLocations> createState() => _CheckinLocationsState();
}

class _CheckinLocationsState extends State<CheckinLocations> {
  List<AttendancePlace> _places = const [];
  AttendancePlace? _selected;
  bool _loading = true;
  bool _saving = false;
  bool _failed = false;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CheckinLocations oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session ||
        oldWidget.package.digest != widget.package.digest) {
      _selected = null;
      _places = const [];
      _loading = true;
      _saving = false;
      _failed = false;
      _load();
    }
  }

  Future<void> _load() async {
    final request = ++_request;
    try {
      final places = await widget.session.attendancePlaces(widget.package);
      if (mounted && request == _request) {
        setState(() {
          _places = places;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted && request == _request) setState(() => _failed = true);
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  Future<void> _save(
    List<AttendancePlace> places,
    AttendancePlace? selected,
  ) async {
    final request = ++_request;
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      await widget.session.saveAttendancePlaces(widget.package, places);
      if (!mounted || request != _request) return;
      setState(() {
        _places = places;
        _selected = selected;
      });
      widget.onSelected(selected);
    } catch (_) {
      if (mounted && request == _request) setState(() => _failed = true);
    } finally {
      if (mounted && request == _request) setState(() => _saving = false);
    }
  }

  Future<void> _edit([AttendancePlace? place]) async {
    final session = widget.session;
    final generation = session.trustedScriptViewGeneration;
    final result = await showDialog<AttendancePlace>(
      context: context,
      builder: (_) => _LocationEditor(place: place),
    );
    if (!mounted ||
        result == null ||
        session != widget.session ||
        generation != session.trustedScriptViewGeneration) {
      return;
    }
    final places = [
      for (final p in _places)
        if (p.id != result.id) p,
      result,
    ];
    // Saving a location does not select it for attendance automatically.
    await _save(places, _selected?.id == result.id ? result : _selected);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final enabled = widget.enabled && !_loading && !_saving;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.checkinPlacesTitle,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(l10n.checkinPlacesHelp),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: Text(l10n.checkinNoPlace),
                  selected: _selected == null,
                  onSelected: enabled
                      ? (_) {
                          setState(() => _selected = null);
                          widget.onSelected(null);
                        }
                      : null,
                ),
                for (final place in _places)
                  ChoiceChip(
                    key: ValueKey('checkin-place-${place.id}'),
                    label: Text(place.name),
                    selected: _selected?.id == place.id,
                    onSelected: enabled
                        ? (selected) {
                            setState(() => _selected = selected ? place : null);
                            widget.onSelected(_selected);
                          }
                        : null,
                  ),
              ],
            ),
            if (_selected case final place?) ...[
              const SizedBox(height: 12),
              Text(place.address),
              Text(
                '${l10n.checkinLatitude}: ${place.latitude}\n${l10n.checkinLongitude}: ${place.longitude}',
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: enabled ? () => _edit(place) : null,
                    icon: const Icon(Icons.edit_outlined),
                    label: Text(l10n.checkinPlaceEdit),
                  ),
                  TextButton.icon(
                    onPressed: enabled
                        ? () => _save(
                            _places.where((p) => p.id != place.id).toList(),
                            null,
                          )
                        : null,
                    icon: const Icon(Icons.delete_outline),
                    label: Text(l10n.checkinPlaceDelete),
                  ),
                ],
              ),
            ],
            TextButton.icon(
              onPressed: enabled && _places.length < 16 ? _edit : null,
              icon: const Icon(Icons.add_location_alt_outlined),
              label: Text(l10n.checkinPlaceAdd),
            ),
            if (_loading || _saving) const LinearProgressIndicator(),
            if (_failed)
              Text(
                l10n.checkinPlacesSaveFailed,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    );
  }
}

class _LocationEditor extends StatefulWidget {
  const _LocationEditor({this.place});
  final AttendancePlace? place;
  @override
  State<_LocationEditor> createState() => _LocationEditorState();
}

class _LocationEditorState extends State<_LocationEditor> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.place?.name);
  late final _address = TextEditingController(text: widget.place?.address);
  late final _latitude = TextEditingController(
    text: widget.place?.latitude.toString(),
  );
  late final _longitude = TextEditingController(
    text: widget.place?.longitude.toString(),
  );
  @override
  void dispose() {
    for (final c in [_name, _address, _latitude, _longitude]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    String? coordinate(String? text, double limit) {
      final value = double.tryParse(text?.trim() ?? '');
      return value != null && value.isFinite && value.abs() <= limit
          ? null
          : l10n.checkinCoordinateInvalid;
    }

    return AlertDialog(
      title: Text(
        widget.place == null ? l10n.checkinPlaceAdd : l10n.checkinPlaceEdit,
      ),
      scrollable: true,
      content: SizedBox(
        width: 440,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _name,
                maxLength: 50,
                decoration: InputDecoration(labelText: l10n.checkinPlaceName),
                validator: (v) => v == null || v.trim().isEmpty
                    ? l10n.checkinPlaceRequired
                    : null,
              ),
              TextFormField(
                controller: _address,
                maxLength: 200,
                decoration: InputDecoration(
                  labelText: l10n.checkinPlaceAddress,
                ),
                validator: (v) => v == null || v.trim().isEmpty
                    ? l10n.checkinPlaceRequired
                    : null,
              ),
              TextFormField(
                controller: _latitude,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                decoration: InputDecoration(labelText: l10n.checkinLatitude),
                validator: (v) => coordinate(v, 90),
              ),
              TextFormField(
                controller: _longitude,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                decoration: InputDecoration(labelText: l10n.checkinLongitude),
                validator: (v) => coordinate(v, 180),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () {
            if (!_form.currentState!.validate()) return;
            Navigator.pop(
              context,
              AttendancePlace(
                id:
                    widget.place?.id ??
                    DateTime.now().microsecondsSinceEpoch.toString(),
                name: _name.text.trim(),
                address: _address.text.trim(),
                latitude: double.parse(_latitude.text.trim()),
                longitude: double.parse(_longitude.text.trim()),
              ),
            );
          },
          child: Text(l10n.checkinPlaceSave),
        ),
      ],
    );
  }
}
