/// Broker 端口（Dart 侧）—— mirror `server/src/runtime/broker/ports.ts`。
///
/// `decideInjection`（inject_policy.dart）判 inject(ref, via) 后，由后续运行时经
/// `CredentialResolver` 取凭证值并拼 HTTP 头。Resolver 实现属凭证存储（ADR-012）。
///
/// 🔒 凭证值仅在可信核心内流转，**绝不回交 adapter / UI / 公网服务端**（红线 #1）。
library;

/// 已解析的凭证（核心内部表示）。`value` 是凭证明文/会话值，仅核心可见。
class ResolvedCredential {
  const ResolvedCredential({required this.via, required this.value});

  final String via; // cookie | header
  final String value;
}

/// 据 manifest 声明的 ref 取凭证值。未命中（无此凭证 / 已失效）返回 null。
abstract interface class CredentialResolver {
  Future<ResolvedCredential?> get(String ref);
}
