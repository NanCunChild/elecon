/// 应用级会话状态（原型）。
///
/// 持有单例凭证库、当前选中学校、登录状态与调试开关，供开始面板 / 主壳 / 设置页共享。
/// UI 只取得 [SessionCredentialMetadata]，**绝不取得 store 或凭证值**（红线 #1）。
///
/// §2.8 三档存储接线：启动 [bootstrap] 静默续用 H（若有）或已同意的 S 软件档；
/// 首次持久化前 [ensurePersistentStore] 按硬件可用性 + 用户知情同意裁定 H/S/M。
/// 落盘目录经**可注入的** [blobStoreProvider] 提供；provider 为 null 时退化为内存档 M。
///
/// **静默 mint 阶梯**（ADR-017 §2.7）：按选校装配隐藏 WebView 与 HTTP headless 执行器，
/// 经 manifest forms 与平台能力求交；静默级耗尽后仍由可见登录兜底。
///
/// 🔒🔒 **红线 #1 母凭证换票入 release（本仓所有者显式授权，ADR-017 §4.9 合规审待补）。**
/// 原策略：headless mint 仅 [kDebugMode] 装配、release 关闭（合规灰度）。现按所有者要求
/// 解除 build 门禁，让 release 也能用母票（CASTGC）静默换取下游 session——这是修复
/// 「已登录仍提示需要登录」的核心兜底路径。**但此改动尚未过 ADR-017 §4.9 合规评估
/// （headless 属协议模拟）与人工安全审**：合并前须由人主导补审，AI 不得独自闭环
/// （AGENTS.md §1）。
///
/// 🔒 store / minter 生命周期属核心凭证路径（红线 #1）。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../catalog/schools.dart';
import '../core/adapter_service.dart';
import '../core/attendance_places.dart';
import '../core/messages/archive.dart';
import '../core/widgets/schedule_widget_identity.dart';
import '../core/debug/dev_log.dart';
import '../core/html_stdlib.dart';
import '../core/loader/diagnostics.dart';
import '../core/credential/blob_store.dart';
import '../core/credential/hardware_keystore.dart';
import '../core/credential/hardware_secure_store.dart';
import '../core/credential/secure_store.dart';
import '../core/credential/secure_store_factory.dart';
import '../core/credential/software_secure_store.dart';
import '../core/credential/store.dart';
import '../core/credential/types.dart';
import '../core/login/ensure_credential.dart';
import '../core/login/inappwebview_auth_bridge.dart';
import '../core/login/sso_mint.dart';
import '../core/login/sso_mint_headless.dart';
import '../core/login/sso_mint_hidden_webview.dart';
import '../core/login/webview_login.dart';
import '../core/login/webview_auth_ui_bridge.dart';
import '../core/transport/direct.dart';
import '../core/transport/app_tunnel.dart';
import '../core/transport/hermes/hermes.dart';
import '../core/broker/inject_policy.dart' show BrokerManifestView;
import '../core/scripts/invocation.dart';
import '../core/scripts/manifest.dart';
import '../core/scripts/registry.dart';
import '../core/scripts/credentials.dart';
import '../core/scripts/account_auth.dart';
import '../core/scripts/runtime.dart';
import '../core/scripts/input.dart';
import '../core/scripts/device_input.dart';
import '../core/scripts/http_transport.dart';
import '../core/scripts/websocket_transport.dart';
import '../core/scripts/browser.dart' show ScriptBrowserException;
import '../core/scripts/data_cache.dart';
import '../core/scripts/query_form_cache.dart';
import '../core/scripts/readiness.dart';
export '../core/scripts/data_cache.dart' show ScriptCachedData;
export '../core/attendance_places.dart' show AttendancePlace;
export '../core/messages/archive.dart' show MessageArchiveView, ArchivedMessage;

part 'script_session.dart';
part 'schedule_widget_session.dart';
part 'query_form_session.dart';
part 'attendance_session.dart';
part 'message_session.dart';
part 'network_session.dart';
part 'app_tunnel_session.dart';

const String _sessionMetaBlob = 'session.json';

enum SessionCredentialStatus { active, expired, revoked }

enum SessionCredentialSensitivity { standard, master }

enum SessionCredentialProtection { hardware, software, memory, mixed }

/// UI 可见的凭证登记信息。只含 ADR-012 §2.7 决策 B 认定的非密元数据。
class SessionCredentialMetadata {
  const SessionCredentialMetadata({
    required this.ref,
    required this.status,
    required this.sensitivity,
    required this.protection,
  });

  final String ref;
  final SessionCredentialStatus status;
  final SessionCredentialSensitivity sensitivity;
  final SessionCredentialProtection protection;
}

class SessionController extends ChangeNotifier {
  SessionController({
    HardwareKeyStore hardware = const UnavailableHardwareKeyStore(),
    Future<BlobStore?> Function()? blobStoreProvider,
    Future<AdapterService?> Function()? adapterServiceProvider,
    List<SchoolDescriptor> initialSchools = const [],
    SsoMinter? ssoMinter,
    Future<bool> Function(VisibleLoginRequest request)? onVisibleLogin,
    List<AppTunnelProvider>? appTunnelProviders,
    HermesNativeBinding? hermesBinding,
  }) : _store = CredentialStore(store: InMemorySecureStore(releaseMode: false)),
       _hardware = hardware,
       _blobStoreProvider = blobStoreProvider,
       _adapterServiceProvider = adapterServiceProvider,
       _availableSchools = List.unmodifiable(initialSchools),
       _legacySchoolsLoaded = initialSchools.isNotEmpty,
       _ssoMinter = ssoMinter,
       _ssoMinterInjected = ssoMinter != null,
       _onVisibleLogin = onVisibleLogin,
       _hermesBinding = hermesBinding ?? HermesNativeBinding(),
       _injectedAppTunnelProviders = appTunnelProviders == null
           ? null
           : List.unmodifiable(appTunnelProviders);

  final List<AppTunnelProvider>? _injectedAppTunnelProviders;
  final HermesNativeBinding _hermesBinding;
  late final AppTunnelRouting _networkRoutes = AppTunnelRouting(
    blobs: _resolveBlobs,
    providers: _injectedAppTunnelProviders ?? _defaultAppTunnelProviders(),
  );
  bool _changingNetwork = false;
  int _legacyNetworkRuns = 0;
  final _legacyAuthBridges = <WebViewAuthUiBridge>{};

  final HardwareKeyStore _hardware;
  final Future<BlobStore?> Function()? _blobStoreProvider;

  /// adapter 运行时服务懒装配（生产 = path_provider 目录 + 端点 D；测试注入替身）。
  final Future<AdapterService?> Function()? _adapterServiceProvider;
  AdapterService? _adapterService;

  /// 静默签票执行器（ADR-017）；null = 跳过 L1，缺凭证直接可见登录（mint 闭环 §4.2）。
  SsoMinter? _ssoMinter;

  /// 构造注入或 [ssoMinter] setter 提供的 minter：不自动装配 / 不随选校重建。
  bool _ssoMinterInjected;

  /// 自动装配 HTTP headless 级时持有的 transport（需 [dispose] 释放连接池）。
  DirectTransport? _mintTransport;

  /// 可见登录回调（UI 注入）；null = ensure 返回 needVisibleLogin，由调用方引导登录。
  final Future<bool> Function(VisibleLoginRequest request)? _onVisibleLogin;

  /// 当前静默签票执行器（测试 / 诊断只读）。
  @visibleForTesting
  SsoMinter? get ssoMinter => _ssoMinter;

  /// 创建可信 WebView 认证桥。UI 只持有桥及无秘密状态，不获得 store/cookie 能力（红线 #1）。
  Future<WebViewAuthUiBridge> createWebViewAuthBridge({
    required LoginManifestView login,
    String? initialUrl,
    String? requiredRef,
    Set<String> tlsProceedHosts = const {},
  }) async {
    _requireProtectedStoreAccess();
    final school = _school;
    final generation = _scripts.generation;
    final store = _store;
    if (school == null ||
        _changingNetwork ||
        await _networkRoutes.choice(school.id) != null) {
      throw const AppTunnelException('app_tunnel_legacy_unsupported');
    }
    bool active() =>
        !_scripts.disposed &&
        !hardwareUnlockFailed &&
        !_changingNetwork &&
        generation == _scripts.generation &&
        _school?.id == school.id &&
        identical(store, _store);
    if (!active()) throw const AppTunnelException('app_tunnel_cancelled');
    final bridge = InAppWebViewAuthBridge(
      login: login,
      putCredential: (entry) {
        if (active()) store.put(entry);
      },
      initialUrl: initialUrl,
      requiredRef: requiredRef,
      tlsProceedHosts: tlsProceedHosts,
    );
    _legacyAuthBridges.add(bridge);
    bridge.completion.then<void>(
      (_) => _legacyAuthBridges.remove(bridge),
      onError: (Object _) => _legacyAuthBridges.remove(bridge),
    );
    return bridge;
  }

  /// 测试注入或覆盖 minter；此后不再自动装配 headless。
  set ssoMinter(SsoMinter? minter) {
    _disposeAutoMint();
    _ssoMinterInjected = true;
    _ssoMinter = minter;
  }

  // Identity changes invalidate assistant grants independently from ordinary
  // execution cancellation (backgrounding, locale changes and stale queries).
  int _identityRevision = 0;
  int get identityRevision => _identityRevision;
  void _invalidateIdentity({bool notify = true}) {
    _identityRevision++;
    if (notify) notifyListeners();
  }

  CredentialStore _store;
  SecureStore? _secure; // 已裁定的底层后端（用于 flush 等能力探测）
  BlobStore? _blobs;
  Future<void> _sessionPersistChain = Future<void>.value();
  Future<void>? _bootstrapFuture;
  bool _isRestored = false;
  bool get isRestored => _isRestored;
  bool _storeResolved = false;

  SchoolDescriptor? _school;
  List<SchoolDescriptor> _availableSchools;
  bool _legacySchoolsLoaded;
  Future<void>? _schoolCatalogLoad;
  bool _debugLog = kDebugMode;

  /// ADR-095: unavailable protected data stays blocked until explicit recovery.
  bool _hardwareUnlockFailed = false;
  bool _recoverExistingSoftwareStore = false;
  Future<bool>? _protectedStoreRecovery;
  bool get isRetryingProtectedStore => _protectedStoreRecovery != null;
  Future<void>? _persistentStoreSelection;
  int? _persistentStoreSelectionGeneration;
  int? _persistentStoreSelectionIdentity;
  CredentialStore? _persistentStoreSelectionStore;

  SchoolDescriptor? get selectedSchool => _school;
  List<SchoolDescriptor> get availableSchools => _availableSchools;
  bool get isConfigured => _school != null;
  bool get debugLog => _debugLog;
  // ADR-034: a different school's credentials do not imply this school is logged in.
  Iterable<CredentialEntry> get _selectedCredentialEntries =>
      hardwareUnlockFailed
      ? const []
      : _store.list().where(
          (entry) =>
              entry.type != ScriptDataCache.type &&
              entry.type != ScriptQueryFormCache.type &&
              entry.type != ScheduleWidgetIdentityStore.type &&
              entry.type != ScriptReadinessStore.type &&
              entry.type != ScriptAccountStore.type &&
              entry.type != AttendancePlacesStore.type &&
              entry.type != MessageArchiveStore.type &&
              entry.type != HermesConfigStore.type &&
              entry.type != HermesAccountStore.type &&
              (_school == null || entry.schoolId == _school!.id),
        );

  /// Local credential presence only; scripts may refresh expired records and
  /// this does not verify the server-side login state (ADR-035 §2–§3).
  bool get isLoggedIn => _selectedCredentialEntries.isNotEmpty;
  int get credentialCount => _selectedCredentialEntries.length;

  /// Original H materials remain intact; no school access or fallback is allowed.
  bool get hardwareUnlockFailed => _hardwareUnlockFailed;

  /// 已收割凭证的 ref 列表（升序）；仅名字，**不含值**。
  List<String> get credentialRefs =>
      (credentialMetadata.map((e) => e.ref).toList())..sort();

  /// 已收割凭证的值无关登记信息；不包含 value、scope、type 或可重放等价物（红线 #1）。
  List<SessionCredentialMetadata> get credentialMetadata => List.unmodifiable(
    _selectedCredentialEntries.map(
      (entry) => SessionCredentialMetadata(
        ref: entry.ref,
        status: entry.status == CredentialStatus.revoked
            ? SessionCredentialStatus.revoked
            : entry.expiresAt != null &&
                  DateTime.now().millisecondsSinceEpoch >= entry.expiresAt!
            ? SessionCredentialStatus.expired
            : SessionCredentialStatus.values.byName(entry.status.name),
        sensitivity: SessionCredentialSensitivity.values.byName(
          entry.sensitivity.name,
        ),
        protection: SessionCredentialProtection.values.byName(
          entry.protection.name,
        ),
      ),
    ),
  );

  /// 当前凭证的持久保护档汇总；只由非密 metadata 计算。
  SessionCredentialProtection? get credentialProtection {
    final levels = credentialMetadata.map((e) => e.protection).toSet();
    if (levels.isEmpty) return null;
    if (levels.length == 1) return levels.single;
    return SessionCredentialProtection.mixed;
  }

  /// 启动引导：优先静默续用 H 硬件档，其次已同意的 S 软件档；无持久化则保持
  /// 默认内存档，待首次登录时 [ensurePersistentStore] 裁定。
  ///
  /// H 档存在但 TEE/SE 无法 unwrap / 密文库损坏 → 置
  /// [hardwareUnlockFailed]，保留原材料和选校，等待显式重试。
  Future<void> bootstrap() => _bootstrapFuture ??= _bootstrapLocal();

  Future<void> _bootstrapLocal() async {
    final blobs = await _resolveBlobs();
    if (_scripts.disposed) return;
    var hasHardwareStore = false;
    var hasSoftwareStore = false;
    if (blobs != null) {
      try {
        hasHardwareStore = await HardwareSecureStore.hasPersisted(blobs);
        if (!hasHardwareStore) {
          hasSoftwareStore = await SoftwareSecureStore.hasValidKeyMaterial(
            blobs,
          );
          if (!hasSoftwareStore &&
              await HardwareSecureStore.hasEncryptedImage(blobs)) {
            if (_scripts.disposed) return;
            _blockProtectedStore();
          }
        }
      } catch (_) {
        // An unreadable key file is not evidence that no protected store
        // exists. Preserve it and let the explicit recovery path try again.
        if (_scripts.disposed) return;
        _blockProtectedStore();
      }
    }
    if (_scripts.disposed) return;
    if (hasHardwareStore && blobs != null) {
      // Existing H data must never use the first-save availability probe,
      // which may create a key. Only the original key may unwrap this store.
      _hardwareUnlockFailed = true;
      final generation = trustedScriptViewGeneration;
      final identity = identityRevision;
      try {
        final recovered = await HardwareSecureStore.openExisting(
          _hardware,
          blobs,
        );
        if (_scripts.disposed) return;
        if (generation == trustedScriptViewGeneration &&
            identity == identityRevision) {
          _adoptRecoveredStore(recovered);
        }
      } on HardwareUnlockException {
        if (_scripts.disposed) return;
        _blockProtectedStore();
      }
    } else if (!hardwareUnlockFailed && blobs != null && hasSoftwareStore) {
      try {
        final recovered = await SoftwareSecureStore.openExisting(blobs);
        if (_scripts.disposed) return;
        _replaceStore(recovered);
        _storeResolved = true;
      } catch (_) {
        if (_scripts.disposed) return;
        _blockProtectedStore(software: true);
      }
    }
    // ADR-060: approved local scripts and protected caches never wait for the
    // unrelated V1 distribution network. Its original loader remains in use
    // when the saved school actually belongs to that compatibility path.
    await _restoreScriptSchools();
    if (_scripts.disposed) return;
    _school = blobs == null ? null : await _loadSelectedSchool(blobs);
    if (_school == null &&
        blobs != null &&
        await blobs.read(_sessionMetaBlob) != null) {
      await loadSchoolChoices();
      _school = await _loadSelectedSchool(blobs);
    }
    if (_scripts.disposed) return;
    if (!hardwareUnlockFailed) _wireSsoMinterFor(_school);
    _isRestored = true;
    notifyListeners();
  }

  /// ADR-060: the school picker can populate V1 choices after it is visible.
  /// This never changes the current school or authorizes execution.
  Future<void> loadSchoolChoices() {
    if (_legacySchoolsLoaded || _scripts.disposed) return Future.value();
    if (_schoolCatalogLoad != null) return _schoolCatalogLoad!;
    final future = () async {
      try {
        final legacy = await _loadAvailableSchools();
        if (_scripts.disposed) return;
        _availableSchools = List.unmodifiable([
          ..._availableSchools,
          for (final school in legacy)
            if (!_availableSchools.any((existing) => existing.id == school.id))
              school,
        ]);
        _legacySchoolsLoaded = true;
        notifyListeners();
      } catch (_) {
        // Optional distribution failure leaves local choices usable and may
        // be retried on a later visit to the picker.
      }
    }();
    _schoolCatalogLoad = future;
    return future.whenComplete(() {
      if (identical(_schoolCatalogLoad, future)) _schoolCatalogLoad = null;
    });
  }

  Future<List<SchoolDescriptor>> _loadAvailableSchools() async {
    final service = await _resolveAdapterService();
    if (service == null) return const [];
    final schools = <SchoolDescriptor>[];
    for (final adapterId in schoolAdapterIds) {
      final school = await service.describeSchool(adapterId);
      if (school != null) schools.add(school);
    }
    return List.unmodifiable(schools);
  }

  void _blockProtectedStore({bool software = false}) {
    _hardwareUnlockFailed = true;
    _recoverExistingSoftwareStore = software;
    _cancelTrustedScripts();
    _disposeAutoMint();
    _invalidateIdentity(notify: false);
  }

  /// ADR-095: one explicit, non-destructive attempt shared by all callers.
  Future<bool> retryProtectedStore({bool Function()? isCurrent}) {
    if (_scripts.disposed) return Future.value(false);
    if (_protectedStoreRecovery case final pending?) return pending;
    if (!hardwareUnlockFailed || !_isRestored || isCurrent?.call() == false) {
      return Future.value(false);
    }
    final generation = trustedScriptViewGeneration;
    final identity = identityRevision;
    final store = _store;
    late final Future<bool> pending;
    pending = _recoverProtectedStore(generation, identity, store, isCurrent)
        .whenComplete(() {
          if (identical(_protectedStoreRecovery, pending)) {
            _protectedStoreRecovery = null;
          }
          if (!_scripts.disposed) notifyListeners();
        });
    _protectedStoreRecovery = pending;
    notifyListeners();
    return pending;
  }

  Future<bool> _recoverProtectedStore(
    int generation,
    int identity,
    CredentialStore previous,
    bool Function()? isCurrent,
  ) async {
    bool active() =>
        !_scripts.disposed &&
        hardwareUnlockFailed &&
        generation == trustedScriptViewGeneration &&
        identity == identityRevision &&
        (isCurrent?.call() ?? true) &&
        identical(previous, _store);
    try {
      final blobs = await _resolveBlobs();
      if (blobs == null || !active()) return false;
      final recovered = _recoverExistingSoftwareStore
          ? await SoftwareSecureStore.openExisting(blobs)
          : await HardwareSecureStore.openExisting(_hardware, blobs);
      if (!active()) return false;
      // The previous store is inaccessible, so recovery must not merge any
      // placeholder entries into the original encrypted database.
      _adoptRecoveredStore(recovered);
      return true;
    } catch (_) {
      // Keep the original materials and the blocking state even for corrupt
      // bytes. A subsequent explicit attempt may succeed after platform repair.
      return false;
    }
  }

  void _adoptRecoveredStore(SecureStore recovered) {
    _cancelTrustedScripts();
    _secure = recovered;
    _store = CredentialStore(store: recovered);
    _storeResolved = true;
    _hardwareUnlockFailed = false;
    _invalidateIdentity(notify: false);
    _wireSsoMinterFor(_school);
  }

  /// 首次持久化前确保后端就绪（§2.8）。无硬件 → 经 [confirmSoftwareFallback]
  /// （通常弹警告框）选 S 软件档或 M 内存档。已定档则 no-op。
  Future<void> ensurePersistentStore({
    required Future<bool> Function() confirmSoftwareFallback,
  }) {
    try {
      _requireProtectedStoreAccess();
    } catch (error, stack) {
      return Future.error(error, stack);
    }
    if (_storeResolved) return Future.value();
    final generation = trustedScriptViewGeneration;
    final identity = identityRevision;
    final store = _store;
    if (_persistentStoreSelection case final pending?) {
      if (_persistentStoreSelectionGeneration == generation &&
          _persistentStoreSelectionIdentity == identity &&
          identical(_persistentStoreSelectionStore, store)) {
        return pending;
      }
      return Future.error(StateError('script_cancelled'));
    }
    late final Future<void> pending;
    pending =
        _selectPersistentStore(
          generation,
          identity,
          store,
          confirmSoftwareFallback,
        ).whenComplete(() {
          if (identical(_persistentStoreSelection, pending)) {
            _persistentStoreSelection = null;
            _persistentStoreSelectionGeneration = null;
            _persistentStoreSelectionIdentity = null;
            _persistentStoreSelectionStore = null;
          }
        });
    _persistentStoreSelection = pending;
    _persistentStoreSelectionGeneration = generation;
    _persistentStoreSelectionIdentity = identity;
    _persistentStoreSelectionStore = store;
    return pending;
  }

  Future<void> _selectPersistentStore(
    int generation,
    int identity,
    CredentialStore store,
    Future<bool> Function() confirmSoftwareFallback,
  ) async {
    bool active() =>
        !_scripts.disposed &&
        !hardwareUnlockFailed &&
        generation == trustedScriptViewGeneration &&
        identity == identityRevision &&
        identical(store, _store);
    void check() {
      _requireProtectedStoreAccess();
      if (!active()) throw StateError('script_cancelled');
    }

    void unavailable({bool software = false}) {
      _blockProtectedStore(software: software);
      notifyListeners();
      throw StateError('protected_store_unavailable');
    }

    final blobs = await _resolveBlobs();
    check();
    if (blobs == null) {
      _storeResolved = true; // 无落盘能力（如 path_provider 未接入）→ 内存档 M
      return;
    }
    Future<bool> probe(Future<bool> Function() read) async {
      try {
        final found = await read();
        check();
        return found;
      } catch (_) {
        check();
        unavailable();
        return false;
      }
    }

    final hasHardware = await probe(
      () => HardwareSecureStore.hasPersisted(blobs),
    );
    check();
    if (hasHardware) unavailable();
    final hasSoftware = await probe(
      () => SoftwareSecureStore.hasValidKeyMaterial(blobs),
    );
    check();
    if (hasSoftware) {
      final SoftwareSecureStore recovered;
      try {
        recovered = await SoftwareSecureStore.openExisting(blobs);
      } catch (_) {
        check();
        unavailable(software: true);
        return;
      }
      check();
      _replaceStore(recovered);
      _storeResolved = true;
      notifyListeners();
      return;
    }
    final hasImage = await probe(
      () => HardwareSecureStore.hasEncryptedImage(blobs),
    );
    check();
    if (hasImage) unavailable();
    final resolved = await resolveSecureStore(
      hardware: _hardware,
      blobs: blobs,
      confirmSoftwareFallback: confirmSoftwareFallback,
      isActive: active,
    );
    check();
    _replaceStore(resolved);
    _storeResolved = true;
    notifyListeners();
  }

  void _requireProtectedStoreAccess() {
    if (hardwareUnlockFailed) throw StateError('protected_store_unavailable');
    if (_scripts.disposed) throw StateError('script_cancelled');
  }

  /// durability 屏障：H/S 档等待挂起的持久化落盘。收割后调用。
  Future<void> flush() async {
    await _flushCredentialBackend(_secure);
    await _sessionPersistChain;
  }

  Future<void> _flushCredentialBackend(SecureStore? backend) async {
    if (backend is SoftwareSecureStore) await backend.flush();
    if (backend is HardwareSecureStore) await backend.flush();
  }

  Future<BlobStore?> _resolveBlobs() async {
    if (_blobs != null) return _blobs;
    final provider = _blobStoreProvider;
    if (provider == null) return null;
    _blobs = await provider();
    return _blobs;
  }

  Future<SchoolDescriptor?> _loadSelectedSchool(BlobStore blobs) async {
    final raw = await blobs.read(_sessionMetaBlob);
    if (raw == null) return null;
    try {
      final json = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
      final id = json['selectedSchoolId'];
      if (id is! String) return null;
      for (final school in _availableSchools) {
        if (school.id == id) return school;
      }
    } catch (_) {
      // 损坏的非敏感会话元数据不影响凭证库，按未选校处理。
    }
    return null;
  }

  void _scheduleSessionPersist() {
    _sessionPersistChain = _sessionPersistChain
        .then((_) async {
          final blobs = await _resolveBlobs();
          if (blobs == null) return;
          final school = _school;
          if (school == null) {
            await blobs.delete(_sessionMetaBlob);
            return;
          }
          await blobs.write(
            _sessionMetaBlob,
            utf8.encode(jsonEncode({'selectedSchoolId': school.id})),
          );
        })
        // 非敏感状态写失败不能影响凭证路径；下次启动只会回到选校页。
        .catchError((Object _) {});
  }

  void _replaceStore(SecureStore secure) {
    // ADR-034: first storage selection must preserve sessions acquired in memory.
    for (final entry in _store.list()) {
      final persisted = secure.get(entry.ref);
      if (persisted == null || persisted.acquiredAt <= entry.acquiredAt) {
        secure.put(entry);
      }
    }
    _secure = secure;
    _store = CredentialStore(store: secure);
    _invalidateIdentity();
    // minter 闭包持 store 引用；换后端后须重建（注入 minter 则不动）。
    _wireSsoMinterFor(_school);
  }

  /// 按选校装配 ADR-017 §2.7 静默阶梯；无选校 / 无 ssoMint / 已注入 → null。
  ///
  /// 🔒🔒 红线 #1：原先此处 `!kDebugMode` 门禁把母票换票限制在 debug；现按所有者授权
  /// 解除，release 也装配（见类级文档 §4.9 合规审待补）。母凭证注入边界仍由声明面兜底
  /// （`ids-cas` scope 仅 CAS 域、校验器 M4 拦重叠），非本装配放宽。
  void _wireSsoMinterFor(SchoolDescriptor? school) {
    if (_ssoMinterInjected) return;
    _disposeAutoMint();
    if (school == null || hardwareUnlockFailed) return;
    final login = school.login;
    if (login.ssoMint == null) return;
    final transport = DirectTransport();
    _mintTransport = transport;
    final headless = HeadlessSsoMinter(
      login: login,
      brokerView: login.brokerView,
      resolver: _store,
      transport: transport,
      putCredential: _store.put,
      schoolId: school.id,
    );
    final hidden = HiddenWebViewSsoMinter(
      login: login,
      resolver: _store,
      putCredential: _store.put,
    );
    final supported = <SsoMintForm>{SsoMintForm.headless};
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      supported.add(SsoMintForm.hiddenWebView);
    }
    _ssoMinter = FallbackSsoMinter(
      login: login,
      platform: MintPlatformCapabilities(supported),
      executors: {
        SsoMintForm.hiddenWebView: hidden,
        SsoMintForm.headless: headless,
      },
    );
  }

  void _disposeAutoMint() {
    _mintTransport?.close();
    _mintTransport = null;
    if (!_ssoMinterInjected) _ssoMinter = null;
  }

  void selectSchool(SchoolDescriptor school) {
    if (_school?.id == school.id) return;
    _cancelTrustedScripts();
    _school = school;
    _invalidateIdentity(notify: false);
    _wireSsoMinterFor(school);
    _scheduleSessionPersist();
    notifyListeners();
  }

  /// ADR-035 §2: navigation to school selection is not a credential reset.
  void clearSchoolSelection() {
    _cancelTrustedScripts();
    _school = null;
    _invalidateIdentity(notify: false);
    _wireSsoMinterFor(null);
    _scheduleSessionPersist();
    notifyListeners();
  }

  String get scriptLocale => _scripts.locale;

  /// A language change invalidates in-flight presentation and its cache reads.
  /// It does not reinstall scripts or retry operations with side effects.
  set scriptLocale(String value) {
    final next = normalizeScriptLocale(value) ?? 'zh';
    if (_scripts.locale == next || _scripts.disposed) return;
    _scripts.locale = next;
    _cancelTrustedScripts();
    notifyListeners();
  }

  /// 登录收割完成后调用——store 已被收割路径写入，这里只触发 UI 刷新。
  void onCredentialsChanged({bool identityChanged = false}) {
    if (identityChanged) _invalidateIdentity(notify: false);
    notifyListeners();
  }

  Future<AdapterService?> _resolveAdapterService() async {
    if (_adapterService != null) return _adapterService;
    final provider = _adapterServiceProvider;
    if (provider == null) return null;
    _adapterService = await provider();
    return _adapterService;
  }

  /// 🔒 跑当前选中学校的 adapter capability（ensure 凭证 → loadAdapter → runLoadedAdapter）。
  ///
  /// 凭证解析器固定为本会话的私有 store（凭证只在核心闭包侧注入，UI/本方法不触其值，红线 #1）。
  /// 全程 fail-closed，归一化为 [CapabilityRun]：
  /// - 未选校 / 学校未接入 adapter / 运行时未装配 → [CapabilityFailureKind.load]
  /// - 能力所需凭证 ensure 未就绪 → [CapabilityFailureKind.auth]
  /// 绝不上抛。
  Future<CapabilityRun> runCapability(
    String capability, {
    Map<String, dynamic>? params,
    bool interactive = true,
    String? htmlStdlib,
    void Function(String level, String message)? onLog,
    void Function(AdapterDiagnostic diagnostic)? onDiagnostic,
  }) async {
    if (hardwareUnlockFailed) {
      return const CapabilityRun.failed(
        CapabilityFailureKind.run,
        'protected_store_unavailable',
      );
    }
    try {
      params = ScriptInvocation.snapshotParams(params);
    } catch (_) {
      return const CapabilityRun.failed(
        CapabilityFailureKind.run,
        'input_invalid_request',
      );
    }
    final school = _school;
    final generation = trustedScriptViewGeneration;
    if (school == null) {
      return const CapabilityRun.failed(CapabilityFailureKind.load, '未选校');
    }
    ScriptPackage? local;
    var blockedLocalProvider = false;
    final scriptSchool = school.adapterId.startsWith('script:');
    try {
      final registry = await scriptRegistry;
      local = registry.provider(school.id, capability);
      blockedLocalProvider = registry.blocksLegacyFallback(
        school.id,
        capability,
      );
    } catch (_) {
      if (scriptSchool) {
        return const CapabilityRun.failed(
          CapabilityFailureKind.load,
          'script_registry_unavailable',
        );
      }
      // Optional local registry I/O must not stop the legacy official path.
    }
    if (_school?.id != school.id ||
        generation != trustedScriptViewGeneration ||
        _scripts.disposed) {
      return const CapabilityRun.failed(
        CapabilityFailureKind.run,
        'script_cancelled',
      );
    }
    if (local != null) {
      return runTrustedScript(
        local.manifest.id,
        capability,
        expectedDigest: local.digest,
        params: params,
        interactive: interactive,
        htmlStdlib: htmlStdlib,
        onLog: onLog,
      );
    }
    // ADR-043 §1: an incompatible local selection or a local-list entity
    // must never fall through into an unrelated V1 handler.
    if (blockedLocalProvider) {
      return const CapabilityRun.failed(
        CapabilityFailureKind.load,
        'script_provider_unavailable',
      );
    }
    // ADR-034 §2: local source identities are never catalog adapter IDs.
    if (scriptSchool) {
      return const CapabilityRun.failed(
        CapabilityFailureKind.load,
        'script_capability_unavailable',
      );
    }
    try {
      if (_changingNetwork || await _networkRoutes.choice(school.id) != null) {
        return const CapabilityRun.failed(
          CapabilityFailureKind.run,
          'app_tunnel_legacy_unsupported',
        );
      }
    } on AppTunnelException catch (error) {
      return CapabilityRun.failed(CapabilityFailureKind.run, error.code);
    }
    if (generation != trustedScriptViewGeneration || _school?.id != school.id) {
      return const CapabilityRun.failed(
        CapabilityFailureKind.run,
        'script_cancelled',
      );
    }
    _legacyNetworkRuns++;
    try {
      final adapterId = school.adapterId;
      final required =
          school.capabilityCredentials[capability] ?? const <String>[];
      if (required.isNotEmpty) {
        // 闸门用的 active 判定（store.hasActive + 类型匹配）。抽成具名闭包，让诊断日志
        // 与 ensure 用**同一**判据，避免日志与实际闸门口径不一致。
        bool gateHasActive(String sid, String ref) {
          if (!_store.hasActive(schoolId: sid, ref: ref)) return false;
          final expected = school.login.brokerView.credentials[ref];
          if (expected == null) return false;
          return _store.list().any(
            (entry) =>
                entry.schoolId == sid &&
                entry.ref == ref &&
                entry.status == CredentialStatus.active &&
                entry.type == expected.type,
          );
        }

        // 🔒 诊断打点（runtime 类，release 丢弃，红线 #1）：只记 ref 名 / 布尔态 / 装配位，
        // 绝不记凭证值。用于回答「已登录仍提示需要登录」到底缺哪一环。
        final preState = required
            .map(
              (ref) =>
                  '$ref=${gateHasActive(school.id, ref) ? "active" : "missing"}',
            )
            .join(", ");
        DevLog.instance.runtime(
          'ensure[$capability] 入场：需 [$preState] | '
          '母票(sso-master)=${_store.hasActiveSsoMaster(school.id) ? "有" : "无"} | '
          'minter=${_ssoMinter != null ? "已装配" : "未装配"}',
        );

        final ensured = await ensureCredentials(
          schoolId: school.id,
          refs: required,
          hasActive: gateHasActive,
          hasSsoMaster: _store.hasActiveSsoMaster,
          login: school.login,
          minter: _ssoMinter,
          onVisibleLogin: _onVisibleLogin,
        );

        final postState = required
            .map(
              (ref) =>
                  '$ref=${gateHasActive(school.id, ref) ? "active" : "missing"}',
            )
            .join(", ");
        DevLog.instance.runtime(
          'ensure[$capability] 结果：${ensured.status.name}'
          '${ensured.reason != null ? "（${ensured.reason}）" : ""} | 收场态 [$postState]',
        );

        if (!ensured.isReady) {
          return CapabilityRun.failed(
            CapabilityFailureKind.auth,
            ensured.reason ?? '需要登录',
          );
        }
      }
      if (generation != trustedScriptViewGeneration ||
          _school?.id != school.id) {
        return const CapabilityRun.failed(
          CapabilityFailureKind.run,
          'script_cancelled',
        );
      }
      return await _runOn(
        adapterId,
        capability,
        params: params,
        htmlStdlib: htmlStdlib,
        onLog: onLog,
        onDiagnostic: onDiagnostic,
      );
    } finally {
      _legacyNetworkRuns--;
    }
  }

  /// Debug-only direct adapter entry for distribution and runtime smoke tests.
  /// Production callers must use [runCapability] so the selected school owns
  /// the adapter identity.
  Future<CapabilityRun> runAdapterCapability({
    required String adapterId,
    required String capability,
    Map<String, dynamic>? params,
    String? htmlStdlib,
    void Function(String level, String message)? onLog,
    void Function(AdapterDiagnostic diagnostic)? onDiagnostic,
  }) async {
    if (!kDebugMode) {
      return const CapabilityRun.failed(
        CapabilityFailureKind.load,
        '测试 adapter 入口仅在 debug build 可用',
      );
    }
    return _runOn(
      adapterId,
      capability,
      params: params,
      htmlStdlib: htmlStdlib,
      onLog: onLog,
      onDiagnostic: onDiagnostic,
    );
  }

  /// 🔒 [runCapability] / [runAdapterCapability] 的公共尾：解析已装配的 adapter 运行时并执行。
  /// 凭证解析器固定为本会话私有 store（凭证只在核心闭包侧注入，本方法不触其值，红线 #1）。
  /// 运行时未装配 → [CapabilityFailureKind.load]（不上抛）。adapterId 的**来源**（选校 vs debug 直传）
  /// 与门禁由两个公开入口各自裁定，本方法只做「有 service 就跑」。
  ///
  /// [onLog] / [onDiagnostic] 默认桥接到 [DevLog]（client 唯一观测 sink）；调用方可叠加。
  Future<CapabilityRun> _runOn(
    String adapterId,
    String capability, {
    Map<String, dynamic>? params,
    String? htmlStdlib,
    void Function(String level, String message)? onLog,
    void Function(AdapterDiagnostic diagnostic)? onDiagnostic,
  }) async {
    if (hardwareUnlockFailed) {
      return const CapabilityRun.failed(
        CapabilityFailureKind.run,
        'protected_store_unavailable',
      );
    }
    if (capability == 'climate.command') {
      return const CapabilityRun.failed(
        CapabilityFailureKind.run,
        'legacy_command_unavailable',
      );
    }
    final generation = trustedScriptViewGeneration;
    final school = _school;
    final store = _store;
    bool active() =>
        !_scripts.disposed &&
        !hardwareUnlockFailed &&
        !_changingNetwork &&
        generation == trustedScriptViewGeneration &&
        identical(store, _store) &&
        _school?.id == school?.id;
    _legacyNetworkRuns++;
    try {
      final service = await _resolveAdapterService();
      if (service == null) {
        return const CapabilityRun.failed(
          CapabilityFailureKind.load,
          'adapter 运行时未装配',
        );
      }
      // adapter 普遍 import "elecon:html"；调用方未注入时从 app 资产加载（ADR-011）。
      final stdlib = htmlStdlib ?? await loadHtmlStdlib();
      if (!active()) {
        return const CapabilityRun.failed(
          CapabilityFailureKind.run,
          'script_cancelled',
        );
      }
      if (school != null && await _networkRoutes.choice(school.id) != null) {
        return const CapabilityRun.failed(
          CapabilityFailureKind.run,
          'app_tunnel_legacy_unsupported',
        );
      }
      if (!active()) {
        return const CapabilityRun.failed(
          CapabilityFailureKind.run,
          'script_cancelled',
        );
      }
      final result = await service.run(
        adapterId: adapterId,
        capability: capability,
        resolver: store,
        // 🔒 Response Masker 落库端（ADR-026 §2.7）：与 [resolver] 同一个会话私有 store。
        // 收割到的原值只经此进核心存储，adapter 侧只见投影后的 sentinel（红线 #1）。
        maskerSink: (entry) {
          if (active()) store.put(entry);
        },
        params: params,
        htmlStdlib: stdlib,
        onLog: (level, message) {
          DevLog.instance.adapter(level, message);
          onLog?.call(level, message);
        },
        onDiagnostic: (diagnostic) {
          DevLog.instance.runtime(diagnostic.summary);
          onDiagnostic?.call(diagnostic);
        },
      );
      return active()
          ? result
          : const CapabilityRun.failed(
              CapabilityFailureKind.run,
              'script_cancelled',
            );
    } on AppTunnelException catch (error) {
      return CapabilityRun.failed(CapabilityFailureKind.run, error.code);
    } finally {
      _legacyNetworkRuns--;
    }
  }

  void setDebugLog(bool value) {
    if (_debugLog == value) return;
    _debugLog = value;
    notifyListeners();
  }

  /// 登出 = 立即抹除**当前学校**全部凭证（ADR-012 §2.5），保留选校。
  /// 按 [CredentialEntry.schoolId] 过滤——多校共存时不得波及他校凭证。
  /// 未选校时防御性抹除全部（无归属口径宁可多删，隐私优先于可用性）。
  void logout() {
    _requireProtectedStoreAccess();
    _cancelTrustedScripts();
    _invalidateIdentity(notify: false);
    final id = _school?.id;
    for (final e in _store.list()) {
      if (id == null || e.schoolId == id) _store.delete(e.ref);
    }
    notifyListeners();
  }

  /// 彻底重置：抹除凭证并清除选校，回到开始面板。
  void reset() {
    _requireProtectedStoreAccess();
    for (final e in _store.list()) {
      _store.delete(e.ref);
    }
    clearSchoolSelection();
  }

  @override
  void dispose() {
    _cancelTrustedScripts(dispose: true);
    _disposeAutoMint();
    super.dispose();
  }
}
