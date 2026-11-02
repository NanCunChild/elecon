import 'package:flutter/material.dart';
import '../../session/session_scope.dart';
import 'models.dart';
import 'query_section.dart';
import 'capability_source.dart';
import 'section_card.dart';
import 'result_cards.dart' show GenericSectionCard;
import '../../session/session_controller.dart';
import 'schema_decode.dart';

/// The long-tail template consumes data roles, never remote widgets or actions.
class GenericCapabilitySection extends StatefulWidget {
  const GenericCapabilitySection({super.key});
  @override
  State<GenericCapabilitySection> createState() =>
      _GenericCapabilitySectionState();
}

class _GenericCapabilitySectionState extends State<GenericCapabilitySection>
    with CachedQuerySection<GenericCapabilitySection, GenericSection> {
  GenericSection? _data;
  QueryPhase _phase = QueryPhase.idle;
  String? _error;
  @override
  String get cacheCapability => 'generic.section';
  @override
  GenericSection? decodeCache(Object? raw) => genericSectionFromDynamic(raw);
  @override
  void applyCache(GenericSection data) {
    _data = data;
    _phase = QueryPhase.loaded;
  }

  @override
  void clearCache() {
    _data = null;
    _phase = QueryPhase.idle;
    _error = null;
  }

  @override
  void onConfigurationRequired() => _phase = QueryPhase.needConfiguration;
  Future<void> _load({bool configure = false}) async {
    final session = SessionScope.of(context);
    final generation = session.trustedScriptViewGeneration;
    final source = CapabilitySourceScope.maybeOf(context)?.source;
    setState(() => _phase = QueryPhase.loading);
    final outcome = await runDecoded(
      context,
      session,
      cacheCapability,
      params: {if (configure) 'configure': true},
      decode: decodeCache,
    );
    if (!isCurrentQuery(this, session, generation, source)) return;
    setState(() {
      _phase = outcome.needLogin
          ? QueryPhase.needLogin
          : outcome.needConfiguration
          ? QueryPhase.needConfiguration
          : outcome.data == null
          ? QueryPhase.error
          : QueryPhase.loaded;
      _error = outcome.error;
      if (outcome.data != null) _data = outcome.data;
    });
  }

  @override
  Widget build(BuildContext context) {
    final refresh = SectionRefreshButton(
      onPressed: _phase == QueryPhase.loading ? null : _load,
    );
    if (_data != null) {
      return withCacheTime(GenericSectionCard(_data!, trailing: refresh));
    }
    return SectionCard(
      title: '',
      trailing: refresh,
      summary: querySummary(context, _phase),
      child: QueryPhaseBody(
        phase: _phase,
        error: _error,
        onConfigure: () => _load(configure: true),
        onLogin: () async {
          final session = SessionScope.of(context);
          final generation = session.trustedScriptViewGeneration;
          final source = CapabilitySourceScope.maybeOf(context)?.source;
          if (await promptVisibleLogin(
                context,
                session,
                capability: cacheCapability,
              ) &&
              isCurrentQuery(this, session, generation, source)) {
            await _load();
          }
        },
      ),
    );
  }
}
