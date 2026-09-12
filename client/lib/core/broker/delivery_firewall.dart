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
  bool headerCardinalityAttested = false,
}) {
  // ① A3 明文边界（纵深防御；真实解码判定在传输层 seam）。
  if (!transportDecodeOk) {
    throw const DeliveryFirewallException(
      'body_not_plaintext',
      '传输层未能解码为 UTF-8 明文，拒绝交付',
    );
  }

  // ①b P1-04 原始基数边界：传输层不能证明基数时，header 源规则一律拒（与纯引擎分工：
  // 引擎判「已知重复」→ capture_ambiguous，本层判「无从得知」→ 本码）。折叠后的 "a, b"
  // 与单值 "a, b" 不可区分，把它当凭证收割等于在歧义上开口。
  if (!headerCardinalityAttested &&
      rules.any((r) => r.capture.source == 'header')) {
    throw const DeliveryFirewallException(
      'header_cardinality_unattested',
      '传输层无法证明响应头原始基数（P1-04）——header 源 Masker 规则拒交付，绝不收割折叠后的合并值',
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
