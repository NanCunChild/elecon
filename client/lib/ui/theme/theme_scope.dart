/// [ThemeController] 的 InheritedNotifier 下发。
library;

import 'package:flutter/widgets.dart';

import 'theme_controller.dart';

class ThemeScope extends InheritedNotifier<ThemeController> {
  const ThemeScope({
    super.key,
    required ThemeController controller,
    required super.child,
  }) : super(notifier: controller);

  static ThemeController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ThemeScope>();
    assert(scope?.notifier != null, 'ThemeScope 未在上层提供');
    return scope!.notifier!;
  }

  /// 不建立依赖（写偏好时若只需 controller 引用）。
  static ThemeController read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<ThemeScope>();
    assert(scope?.notifier != null, 'ThemeScope 未在上层提供');
    return scope!.notifier!;
  }
}
