/// 应用级会话状态（原型）。
///
/// 持有**单例** [CredentialStore]、当前选中学校、登录状态与调试开关，供开始面板 /
/// 主壳 / 设置页共享。UI 只读状态（登录与否、凭证条数），**绝不读凭证值**（红线 #1）。
///
/// 🔒 store 生命周期属核心凭证路径：原型用 [InMemorySecureStore]（明文内存，仅 debug/dev；
/// release 会 fail-closed，见 ADR-012 §2.1 / secure_store.dart）。真实 OS keystore 后端与
/// 跨重启持久化是上线前硬门槛，尚未接入——本控制器仅在**进程内**保持登录态。
library;

import 'package:flutter/foundation.dart';

import '../catalog/schools.dart';
import '../core/credential/secure_store.dart';
import '../core/credential/store.dart';

class SessionController extends ChangeNotifier {
  SessionController({CredentialStore? store})
      : store = store ??
            CredentialStore(store: InMemorySecureStore(releaseMode: false));

  /// 单例凭证库（收割落点 + 状态来源）。
  final CredentialStore store;

  SchoolDescriptor? _school;

  /// 登录时是否开启 WebView 日志面板（设置页可切换）。
  bool _debugLog = true;

  SchoolDescriptor? get selectedSchool => _school;

  /// 是否已完成选校（决定 RootGate 显示开始面板还是主壳）。
  bool get isConfigured => _school != null;

  bool get debugLog => _debugLog;

  /// 是否已有收割到的凭证（原型口径：库非空即视为已登录）。
  bool get isLoggedIn => store.list().isNotEmpty;

  int get credentialCount => store.list().length;

  /// 已收割凭证的 ref 列表（升序）；仅名字，**不含值**。
  List<String> get credentialRefs =>
      (store.list().map((e) => e.ref).toList())..sort();

  void selectSchool(SchoolDescriptor school) {
    if (_school?.id == school.id) return;
    _school = school;
    notifyListeners();
  }

  /// 登录收割完成后调用——store 已被收割路径写入，这里只触发 UI 刷新。
  void onCredentialsChanged() => notifyListeners();

  void setDebugLog(bool value) {
    if (_debugLog == value) return;
    _debugLog = value;
    notifyListeners();
  }

  /// 登出 = 立即抹除当前学校全部凭证（ADR-012 §2.5），保留选校。
  void logout() {
    for (final e in store.list()) {
      store.delete(e.ref);
    }
    notifyListeners();
  }

  /// 彻底重置：抹除凭证并清除选校，回到开始面板。
  void reset() {
    for (final e in store.list()) {
      store.delete(e.ref);
    }
    _school = null;
    notifyListeners();
  }
}
