/// Broker 响应交付事务原语（ADR-026 §2.4）。
///
/// 调用方必须显式提供已匹配规则、manifest view、commit sink 与 context。本模块不推断策略，
/// 也不提供缺少策略依赖时的 raw fallback。
/// 🔒 红线 #1 承重路径：须人工 + 安全清单复核，不得 AI 独自闭环。
library;

import 'assemble.dart';
import 'inject_policy.dart';
import 'masker_commit.dart';
import 'response_masker.dart';

class DeliveryFirewallException implements Exception {
  const DeliveryFirewallException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'DeliveryFirewallException($code): $message';
}

class DeliveryFirewallOutcome {
  const DeliveryFirewallOutcome({
    required this.response,
    required this.committedCount,
  });

  final ProcessedResponse response;
  final int committedCount;
}

DeliveryFirewallOutcome deliverThroughFirewall({
  required MaskerRawResponse raw,
  required bool transportDecodeOk,
  required List<MaskerRule> rules,
  required BrokerManifestView view,
  required MaskerCommitSink sink,
  required MaskerCommitContext context,
  bool Function()? isCancelled,
}) {
  if (!transportDecodeOk) {
    throw const DeliveryFirewallException(
      'body_not_plaintext',
      '传输层未能解码为 UTF-8 明文，拒绝交付',
    );
  }

  _assertDeliveryActive(isCancelled);
  final outcome = applyResponseMasker(rules, raw);

  // Commit 是不可逆边界；transport 晚到或 Capture 期间取消均不得写 sink。
  _assertDeliveryActive(isCancelled);
  commitMaskerCaptured(outcome.captured, view, sink, context);

  return DeliveryFirewallOutcome(
    response: processResponse(
      RawResponse(
        status: outcome.projected.status,
        headers: outcome.projected.headers,
        body: outcome.projected.body,
      ),
    ),
    committedCount: outcome.captured.length,
  );
}

void _assertDeliveryActive(bool Function()? isCancelled) {
  if (isCancelled?.call() ?? false) {
    throw const DeliveryFirewallException(
      'delivery_cancelled',
      '执行已取消，拒绝 Capture / Commit / 交付',
    );
  }
}
