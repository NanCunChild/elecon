import 'package:flutter/widgets.dart';
import '../../core/ai/app_functions_controller.dart';

class AppFunctionsScope extends InheritedNotifier<AppFunctionsController> {
  const AppFunctionsScope({
    super.key,
    required AppFunctionsController controller,
    required super.child,
  }) : super(notifier: controller);

  static AppFunctionsController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppFunctionsScope>()?.notifier;
}
