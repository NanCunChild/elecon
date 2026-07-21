/// 应用级会话状态（原型）。
///
/// 持有**单例** [CredentialStore]、当前选中学校、登录状态与调试开关，供开始面板 /
/// 主壳 / 设置页共享。UI 只读状态（登录与否、凭证条数），**绝不读凭证值**（红线 #1）。
///
/// §2.8 三档存储接线：启动 [bootstrap] 静默续用 H（若有）或已同意的 S 软件档；
/// 首次持久化前 [ensurePersistentStore] 按硬件可用性 + 用户知情同意裁定 H/S/M。
/// 落盘目录经**可注入的** [blobStoreProvider] 提供；provider 为 null 时退化为内存档 M。
///
/// **L1 headless mint**（ADR-017）：[kDebugMode] 下按选校自动装配 [HeadlessSsoMinter]
/// （`DirectTransport` + 本会话 [store]）；release 不装配（合规灰度，§4.9）。构造注入或
/// [ssoMinter] setter 优先，跳过自动装配。
///
/// 🔒 store / minter 生命周期属核心凭证路径（红线 #1）。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../catalog/schools.dart';
import '../core/adapter_service.dart';
import '../core/debug/dev_log.dart';
import '../core/loader/diagnostics.dart';
import '../core/credential/blob_store.dart';
import '../core/credential/hardware_keystore.dart';
import '../core/credential/hardware_secure_store.dart';
import '../core/credential/secure_store.dart';
import '../core/credential/secure_store_factory.dart';
import '../core/credential/software_secure_store.dart';
import '../core/credential/store.dart';
import '../core/login/ensure_credential.dart';
import '../core/login/sso_mint.dart';
import '../core/login/sso_mint_headless.dart';
import '../core/transport/direct.dart';

const String _sessionMetaBlob = 'session.json';

class SessionController extends ChangeNotifier {
  SessionController({
    CredentialStore? store,
    HardwareKeyStore hardware = const UnavailableHardwareKeyStore(),
    Future<BlobStore?> Function()? blobStoreProvider,
    Future<AdapterService?> Function()? adapterServiceProvider,
    SsoMinter? ssoMinter,
    Future<bool> Function(VisibleLoginRequest request)? onVisibleLogin,
  }) : _store =
           store ??
           CredentialStore(store: InMemorySecureStore(releaseMode: false)),
       _hardware = hardware,
       _blobStoreProvider = blobStoreProvider,
       _adapterServiceProvider = adapterServiceProvider,
       _ssoMinter = ssoMinter,
       _ssoMinterInjected = ssoMinter != null,
       _onVisibleLogin = onVisibleLogin,
       // 注入了 store（测试/自定义）→ 视为已定档，不再重新裁定。
       _storeResolved = store != null;

  final HardwareKeyStore _hardware;
  final Future<BlobStore?> Function()? _blobStoreProvider;

  /// adapter 运行时服务懒装配（生产 = path_provider 目录 + 端点 D；测试注入替身）。
  final Future<AdapterService?> Function()? _adapterServiceProvider;
  AdapterService? _adapterService;

  /// 静默签票执行器（ADR-017）；null = 跳过 L1，缺凭证直接可见登录（mint 闭环 §4.2）。
  SsoMinter? _ssoMinter;

  /// 构造注入或 [ssoMinter] setter 提供的 minter：不自动装配 / 不随选校重建。
  bool _ssoMinterInjected;

  /// 自动装配 [HeadlessSsoMinter] 时持有的 transport（需 [dispose] 释放连接池）。
  DirectTransport? _mintTransport;

  /// 可见登录回调（UI 注入）；null = ensure 返回 needVisibleLogin，由调用方引导登录。
  final Future<bool> Function(VisibleLoginRequest request)? _onVisibleLogin;

  /// 当前静默签票执行器（测试 / 诊断只读）。
  @visibleForTesting
  SsoMinter? get ssoMinter => _ssoMinter;

  /// 测试注入或覆盖 minter；此后不再自动装配 headless。
  set ssoMinter(SsoMinter? minter) {
    _disposeAutoMint();
    _ssoMinterInjected = true;
    _ssoMinter = minter;
  }

  CredentialStore _store;
  SecureStore? _secure; // 已裁定的底层后端（用于 flush 等能力探测）
  BlobStore? _blobs;
  Future<void> _sessionPersistChain = Future<void>.value();
  bool _bootstrapped = false;
  bool _storeResolved;

  SchoolDescriptor? _school;
  bool _debugLog = kDebugMode;

  /// H 档启动解不开时置位；UI 提示后 [acknowledgeHardwareUnlockFailure] 清除。
  bool _hardwareUnlockFailed = false;

  /// 单例凭证库（收割落点 + 状态来源）。
  CredentialStore get store => _store;

  SchoolDescriptor? get selectedSchool => _school;
  bool get isConfigured => _school != null;
  bool get debugLog => _debugLog;
  bool get isLoggedIn => store.list().isNotEmpty;
  int get credentialCount => store.list().length;

  /// 上次 bootstrap 因 TEE/SE 无法 unwrap 而抹除了 H 档凭证。
  bool get hardwareUnlockFailed => _hardwareUnlockFailed;

  /// 已收割凭证的 ref 列表（升序）；仅名字，**不含值**。
  List<String> get credentialRefs =>
      (store.list().map((e) => e.ref).toList())..sort();

  /// 启动引导：优先静默续用 H 硬件档，其次已同意的 S 软件档；无持久化则保持
  /// 默认内存档，待首次登录时 [ensurePersistentStore] 裁定。
  ///
  /// H 档存在但 TEE/SE 无法 unwrap / 密文库损坏 → 抹除 H blob，置
  /// [hardwareUnlockFailed]，保留选校，回到未登录。
  Future<void> bootstrap() async {
    if (_bootstrapped) return;
    _bootstrapped = true;
    final blobs = await _resolveBlobs();
    if (blobs == null) return;
    if (await HardwareSecureStore.hasPersisted(blobs)) {
      if (!await _hardware.isAvailable()) {
        await _failHardwareUnlock(blobs);
      } else {
        try {
          _replaceStore(await HardwareSecureStore.open(_hardware, blobs));
          _storeResolved = true;
        } on HardwareUnlockException {
          await _failHardwareUnlock(blobs);
        }
      }
    } else if (await SoftwareSecureStore.hasPersisted(blobs)) {
      _replaceStore(await SoftwareSecureStore.open(blobs));
      _storeResolved = true;
    }
    _school = await _loadSelectedSchool(blobs);
    _wireSsoMinterFor(_school);
    notifyListeners();
  }

  Future<void> _failHardwareUnlock(BlobStore blobs) async {
    await HardwareSecureStore.wipePersisted(blobs);
    _replaceStore(InMemorySecureStore(releaseMode: false));
    _storeResolved = false;
    _hardwareUnlockFailed = true;
  }

  /// UI 已展示过「硬件无法解密」提示后调用。
  void acknowledgeHardwareUnlockFailure() {
    if (!_hardwareUnlockFailed) return;
    _hardwareUnlockFailed = false;
    notifyListeners();
  }

  /// 首次持久化前确保后端就绪（§2.8）。无硬件 → 经 [confirmSoftwareFallback]
  /// （通常弹警告框）选 S 软件档或 M 内存档。已定档则 no-op。
  Future<void> ensurePersistentStore({
    required Future<bool> Function() confirmSoftwareFallback,
  }) async {
    if (_storeResolved) return;
    final blobs = await _resolveBlobs();
    if (blobs == null) {
      _storeResolved = true; // 无落盘能力（如 path_provider 未接入）→ 内存档 M
      return;
    }
    _replaceStore(
      await resolveSecureStore(
        hardware: _hardware,
        blobs: blobs,
        confirmSoftwareFallback: confirmSoftwareFallback,
      ),
    );
    _storeResolved = true;
    notifyListeners();
  }

  /// durability 屏障：H/S 档等待挂起的持久化落盘。收割后调用。
  Future<void> flush() async {
    final s = _secure;
    if (s is SoftwareSecureStore) await s.flush();
    if (s is HardwareSecureStore) await s.flush();
    await _sessionPersistChain;
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
      for (final school in builtinSchools) {
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
    _secure = secure;
    _store = CredentialStore(store: secure);
    // minter 闭包持 store 引用；换后端后须重建（注入 minter 则不动）。
    _wireSsoMinterFor(_school);
  }

  /// debug 下按选校装配 [HeadlessSsoMinter]（mint 闭环 M1）；release / 无 ssoMint / 已注入 → null。
  void _wireSsoMinterFor(SchoolDescriptor? school) {
    if (_ssoMinterInjected) return;
    _disposeAutoMint();
    if (school == null || !kDebugMode) return;
    final login = school.login;
    if (login.ssoMint == null) return;
    final transport = DirectTransport();
    _mintTransport = transport;
    _ssoMinter = HeadlessSsoMinter(
      login: login,
      brokerView: login.brokerView,
      resolver: _store,
      transport: transport,
      putCredential: _store.put,
      schoolId: school.id,
    );
  }

  void _disposeAutoMint() {
    _mintTransport?.close();
    _mintTransport = null;
    if (!_ssoMinterInjected) _ssoMinter = null;
  }

  void selectSchool(SchoolDescriptor school) {
    if (_school?.id == school.id) return;
    _school = school;
    _wireSsoMinterFor(school);
    _scheduleSessionPersist();
    notifyListeners();
  }

  /// 登录收割完成后调用——store 已被收割路径写入，这里只触发 UI 刷新。
  void onCredentialsChanged() => notifyListeners();

  Future<AdapterService?> _resolveAdapterService() async {
    if (_adapterService != null) return _adapterService;
    final provider = _adapterServiceProvider;
    if (provider == null) return null;
    _adapterService = await provider();
    return _adapterService;
  }

  /// 🔒 跑当前选中学校的 adapter capability（ensure 凭证 → loadAdapter → runLoadedAdapter）。
  ///
  /// 凭证解析器固定为本会话的 [store]（凭证只在核心闭包侧注入，UI/本方法不触其值，红线 #1）。
  /// 全程 fail-closed，归一化为 [CapabilityRun]：
  /// - 未选校 / 学校未接入 adapter / 运行时未装配 → [CapabilityFailureKind.load]
  /// - 能力所需凭证 ensure 未就绪 → [CapabilityFailureKind.auth]
  /// 绝不上抛。
  Future<CapabilityRun> runCapability(
    String capability, {
    Map<String, dynamic>? params,
    String? htmlStdlib,
    void Function(String level, String message)? onLog,
    void Function(AdapterDiagnostic diagnostic)? onDiagnostic,
  }) async {
    final school = _school;
    if (school == null) {
      return const CapabilityRun.failed(CapabilityFailureKind.load, '未选校');
    }
    final adapterId = school.adapterId;
    if (adapterId == null) {
      return CapabilityRun.failed(
        CapabilityFailureKind.load,
        '学校 ${school.id} 尚未接入 adapter',
      );
    }
    final required = school.capabilityCredentials[capability] ?? const <String>[];
    if (required.isNotEmpty) {
      final ensured = await ensureCredentials(
        schoolId: school.id,
        refs: required,
        hasActive: (sid, ref) => _store.hasActive(schoolId: sid, ref: ref),
        hasSsoMaster: _store.hasActiveSsoMaster,
        login: school.login,
        minter: _ssoMinter,
        onVisibleLogin: _onVisibleLogin,
      );
      if (!ensured.isReady) {
        return CapabilityRun.failed(
          CapabilityFailureKind.auth,
          ensured.reason ?? '需要登录',
        );
      }
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
  /// 凭证解析器固定为本会话 [store]（凭证只在核心闭包侧注入，本方法不触其值，红线 #1）。
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
    final service = await _resolveAdapterService();
    if (service == null) {
      return const CapabilityRun.failed(
        CapabilityFailureKind.load,
        'adapter 运行时未装配',
      );
    }
    return service.run(
      adapterId: adapterId,
      capability: capability,
      resolver: _store,
      params: params,
      htmlStdlib: htmlStdlib,
      onLog: (level, message) {
        DevLog.instance.adapter(level, message);
        onLog?.call(level, message);
      },
      onDiagnostic: (diagnostic) {
        DevLog.instance.runtime(diagnostic.summary);
        onDiagnostic?.call(diagnostic);
      },
    );
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
    final id = _school?.id;
    for (final e in store.list()) {
      if (id == null || e.schoolId == id) store.delete(e.ref);
    }
    notifyListeners();
  }

  /// 彻底重置：抹除凭证并清除选校，回到开始面板。
  void reset() {
    for (final e in store.list()) {
      store.delete(e.ref);
    }
    _school = null;
    _wireSsoMinterFor(null);
    _scheduleSessionPersist();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposeAutoMint();
    super.dispose();
  }
}
