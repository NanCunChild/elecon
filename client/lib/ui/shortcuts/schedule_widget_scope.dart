import 'package:flutter/widgets.dart';
import '../../core/widgets/schedule_widget_controller.dart';

class ScheduleWidgetScope extends InheritedNotifier<ScheduleWidgetController> {
  const ScheduleWidgetScope({
    super.key,
    required ScheduleWidgetController controller,
    required super.child,
  }) : super(notifier: controller);
  static ScheduleWidgetController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ScheduleWidgetScope>()
      ?.notifier;
}
