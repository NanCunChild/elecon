import 'package:flutter/material.dart';
import '../../session/session_controller.dart';
import '../../session/capability_query.dart';

/// Display only: profile identity and credential namespaces never change.
class ScriptProfileName extends StatefulWidget {
  const ScriptProfileName({
    super.key,
    required this.session,
    required this.fallback,
    required this.active,
  });
  final SessionController session;
  final String fallback;
  final bool active;
  @override
  State<ScriptProfileName> createState() => _ScriptProfileNameState();
}

class _ScriptProfileNameState extends State<ScriptProfileName> {
  Object? _key;
  Future<String?>? _name;
  Object? _queryAttempt;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) {
      final session = widget.session;
      final authority = (
        session,
        session.selectedSchool?.id,
        session.trustedScriptViewGeneration,
        session.trustedScriptDataGeneration,
        widget.active,
        session.isRestored,
      );
      final key = (authority, session.homeDataRevision);
      if (_key != key) {
        _key = key;
        _name = () async {
          bool current() =>
              mounted &&
              _key == key &&
              identical(widget.session, session) &&
              widget.active == authority.$5 &&
              session.isRestored == authority.$6 &&
              session.selectedSchool?.id == authority.$2 &&
              session.trustedScriptViewGeneration == authority.$3 &&
              session.trustedScriptDataGeneration == authority.$4;
          if (!session.isRestored) return null;
          final queries = CapabilityQueries(session);
          Object? raw = (await queries.latestCachedCapability(
            'profile.me',
          ))?.data;
          if (!current()) return null;
          if (raw == null && widget.active && _queryAttempt != authority) {
            final version = await queries.schemaVersion('profile.me');
            if (!current() || version == null) return null;
            _queryAttempt = authority;
            final run = await queries.runCapability(
              'profile.me',
              interactive: false,
            );
            if (run.ok) raw = run.data;
          }
          if (!current() || raw is! Map) return null;
          final name = raw['name'];
          if (name is! String ||
              name.trim().isEmpty ||
              name.runes.length > 80 ||
              RegExp(
                r'[\x00-\x1f\x7f-\x9f\u061c\u200e\u200f\u2028-\u202e\u2066-\u2069]',
              ).hasMatch(name)) {
            return null;
          }
          return name.trim();
        }();
      }
      return FutureBuilder<String?>(
        key: ValueKey(key),
        future: _name,
        builder: (_, snapshot) => Text(snapshot.data ?? widget.fallback),
      );
    },
  );
}
