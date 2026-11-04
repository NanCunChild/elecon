import 'package:flutter/widgets.dart';
import '../../core/navigation/app_shortcuts_controller.dart';

class AppShortcutsScope extends InheritedNotifier<AppShortcutsController> {
  const AppShortcutsScope({
    super.key,
    required AppShortcutsController controller,
    required super.child,
  }) : super(notifier: controller);

  static AppShortcutsController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppShortcutsScope>()?.notifier;
}
