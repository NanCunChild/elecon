/// [SessionController] 的 InheritedNotifier 下发，供子树读取会话状态并随之重建。
library;

import 'package:flutter/widgets.dart';

import 'session_controller.dart';

class SessionScope extends InheritedNotifier<SessionController> {
  const SessionScope({
    super.key,
    required SessionController controller,
    required super.child,
  }) : super(notifier: controller);

  static SessionController of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<SessionScope>();
    assert(scope?.notifier != null, 'SessionScope 未在上层提供');
    return scope!.notifier!;
  }
}
