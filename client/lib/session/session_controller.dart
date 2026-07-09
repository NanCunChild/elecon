/// 应用级会话状态（原型）。
///
/// 持有**单例** [CredentialStore]、当前选中学校、登录状态与调试开关，供开始面板 /
/// 主壳 / 设置页共享。UI 只读状态（登录与否、凭证条数），**绝不读凭证值**（红线 #1）。
///
/// §2.8 三档存储接线：启动 [bootstrap] 静默续用此前已同意的 S 软件档；首次持久化前
/// [ensurePersistentStore] 按硬件可用性 + 用户知情同意（警告框）裁定 H/S/M 档。
/// 落盘目录经**可注入的** [blobStoreProvider] 提供（当前 path_provider 依赖受阻，
/// 见 docs/notes/build_blockers.md；provider 为 null 时退化为内存档 M，不落盘）。
///
/// 🔒 store 生命周期属核心凭证路径。真实 keystore（H 档）与跨重启持久化随依赖恢复接线。
library;

import 'package:flutter/foundation.dart';

import '../catalog/schools.dart';
import '../core/credential/blob_store.dart';
import '../core/credential/hardware_keystore.dart';
import '../core/credential/secure_store.dart';
import '../core/credential/secure_store_factory.dart';
import '../core/credential/software_secure_store.dart';
import '../core/credential/store.dart';

class SessionController extends ChangeNotifier {
  SessionController({
    CredentialStore? store,
    HardwareKeyStore hardware = const UnavailableHardwareKeyStore(),
    Future<BlobStore?> Function()? blobStoreProvider,
  })  : _store = store ??
            CredentialStore(store: InMemorySecureStore(releaseMode: false)),
        _hardware = hardware,
        _blobStoreProvider = blobStoreProvider,
        // 注入了 store（测试/自定义）→ 视为已定档，不再重新裁定。
        _storeResolved = store != null;

  final HardwareKeyStore _hardware;
  final Future<BlobStore?> Function()? _blobStoreProvider;

  CredentialStore _store;
  SecureStore? _secure; // 已裁定的底层后端（用于 flush 等能力探测）
  BlobStore? _blobs;
  bool _bootstrapped = false;
  bool _storeResolved;

  SchoolDescriptor? _school;
  bool _debugLog = true;

  /// 单例凭证库（收割落点 + 状态来源）。
  CredentialStore get store => _store;

  SchoolDescriptor? get selectedSchool => _school;
  bool get isConfigured => _school != null;
  bool get debugLog => _debugLog;
  bool get isLoggedIn => store.list().isNotEmpty;
  int get credentialCount => store.list().length;

  /// 已收割凭证的 ref 列表（升序）；仅名字，**不含值**。
  List<String> get credentialRefs =>
      (store.list().map((e) => e.ref).toList())..sort();

  /// 启动引导：静默续用此前已知情同意的 S 软件档（不弹警告框）；无持久化则保持
  /// 默认内存档，待首次登录时 [ensurePersistentStore] 裁定。
  Future<void> bootstrap() async {
    if (_bootstrapped) return;
    _bootstrapped = true;
    final provider = _blobStoreProvider;
    if (provider == null) return;
    final blobs = await provider();
    if (blobs == null) return;
    _blobs = blobs;
    if (await SoftwareSecureStore.hasPersisted(blobs)) {
      _replaceStore(await SoftwareSecureStore.open(blobs));
      _storeResolved = true;
      notifyListeners();
    }
  }

  /// 首次持久化前确保后端就绪（§2.8）。无硬件 → 经 [confirmSoftwareFallback]
  /// （通常弹警告框）选 S 软件档或 M 内存档。已定档则 no-op。
  Future<void> ensurePersistentStore({
    required Future<bool> Function() confirmSoftwareFallback,
  }) async {
    if (_storeResolved) return;
    final blobs = _blobs ?? await _blobStoreProvider?.call();
    if (blobs == null) {
      _storeResolved = true; // 无落盘能力（如 path_provider 未接入）→ 内存档 M
      return;
    }
    _blobs = blobs;
    _replaceStore(await resolveSecureStore(
      hardware: _hardware,
      blobs: blobs,
      confirmSoftwareFallback: confirmSoftwareFallback,
    ));
    _storeResolved = true;
    notifyListeners();
  }

  /// durability 屏障：S 软件档下等待挂起的持久化落盘。收割后调用。
  Future<void> flush() async {
    final s = _secure;
    if (s is SoftwareSecureStore) await s.flush();
  }

  void _replaceStore(SecureStore secure) {
    _secure = secure;
    _store = CredentialStore(store: secure);
  }

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
