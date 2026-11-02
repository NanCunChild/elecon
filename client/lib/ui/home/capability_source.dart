import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' show MaterialPageRoute;
import '../../session/capability_query.dart';
import '../../session/session_controller.dart';
export '../../session/capability_query.dart';

/// A native card instance owns its source and title, independently of template type.
class CapabilitySourceScope extends InheritedWidget {
  const CapabilitySourceScope({
    super.key,
    required this.source,
    this.title,
    required super.child,
  });
  final CapabilitySource source;
  final String? title;

  static CapabilitySourceScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CapabilitySourceScope>();
  static CapabilityQueries queriesOf(
    BuildContext context,
    SessionController session,
  ) => CapabilityQueries(session, source: maybeOf(context)?.source);

  @override
  bool updateShouldNotify(CapabilitySourceScope oldWidget) =>
      source != oldWidget.source || title != oldWidget.title;
}

Future<void> openCapabilityPage(BuildContext context, Widget page) {
  final source = CapabilitySourceScope.maybeOf(context)?.source;
  return Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => source == null
          ? page
          : CapabilitySourceScope(source: source, child: page),
    ),
  );
}
