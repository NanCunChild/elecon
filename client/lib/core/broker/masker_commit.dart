/// Response Masker credential 提交原语（ADR-026 §2.4 / §2.8）。
///
/// 仅提供显式 `view` / `sink` / `context` 下的计划与提交；不加载或推断策略，也不接线生产入口。
/// 🔒 红线 #1 承重路径：须人工 + 安全清单复核，不得 AI 独自闭环。
library;

import '../credential/types.dart';
import 'inject_policy.dart';
import 'response_masker.dart';

class MaskerCommitException implements Exception {
  const MaskerCommitException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'MaskerCommitException($code): $message';
}

class MaskerCommitContext {
  const MaskerCommitContext({required this.schoolId, required this.now});

  final String schoolId;
  final int Function() now;
}

typedef MaskerCommitSink = void Function(CredentialEntry entry);

List<CredentialEntry> planMaskerCommit(
  List<CapturedCredential> captured,
  BrokerManifestView view,
  MaskerCommitContext context,
) {
  if (captured.length > 1) {
    throw MaskerCommitException(
      'commit_multiple_credentials',
      '单响应至多一个持久 credential（A6），实得 ${captured.length}',
    );
  }

  return captured
      .map((capture) {
        final declaration = view.credentials[capture.ref];
        if (declaration == null) {
          throw MaskerCommitException(
            'commit_ref_undeclared',
            "收割值 ref '${capture.ref}' 未在 manifest credentials 声明",
          );
        }
        return CredentialEntry(
          ref: capture.ref,
          schoolId: context.schoolId,
          type: declaration.type,
          scope: List<String>.of(declaration.scope),
          value: capture.value,
          acquiredAt: context.now(),
          expiresAt: null,
          status: CredentialStatus.active,
        );
      })
      .toList(growable: false);
}

void commitMaskerCaptured(
  List<CapturedCredential> captured,
  BrokerManifestView view,
  MaskerCommitSink sink,
  MaskerCommitContext context,
) {
  final entries = planMaskerCommit(captured, view, context);
  for (final entry in entries) {
    sink(entry);
  }
}
