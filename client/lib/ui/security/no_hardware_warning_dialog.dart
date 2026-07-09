/// 无硬件加密警告框（ADR-012 §2.8 的「继续 / 取消」闸门）。
///
/// 检测到设备无硬件加密方案时弹出：**强制等待 5 秒**方可点「继续」，如实告知
/// 软件档 ≈ 明文、且**显式点名** SSO 母凭证也将以未受硬件保护形式存于本机
/// （§2.8 母凭证决策）。
/// - 「继续」→ [SoftwareStorageChoice.continueWithSoftware]（启用 S 软件档持久化）。
/// - 「取消」→ [SoftwareStorageChoice.cancelMemoryOnly]（落 M 内存档，退出即需重登）。
///
/// UI 绝不把软件档描述为「受保护加密」（§2.8 / Consequence 9）。真正的加密后端
/// 落地在 store 层（人工主导，红线 #1），本文件只负责知情同意的呈现与闸门。
library;

import 'dart:async';

import 'package:flutter/material.dart';

enum SoftwareStorageChoice { continueWithSoftware, cancelMemoryOnly }

/// 弹出无硬件加密警告框，返回用户选择。barrier 不可点掉、返回键不可退——
/// 必须显式二选一。
Future<SoftwareStorageChoice> showNoHardwareWarningDialog(
  BuildContext context, {
  int waitSeconds = 5,
}) async {
  final choice = await showDialog<SoftwareStorageChoice>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _NoHardwareWarningDialog(waitSeconds: waitSeconds),
  );
  // 极端情况下（不应发生）按内存档兜底——fail toward less trust。
  return choice ?? SoftwareStorageChoice.cancelMemoryOnly;
}

class _NoHardwareWarningDialog extends StatefulWidget {
  const _NoHardwareWarningDialog({required this.waitSeconds});

  final int waitSeconds;

  @override
  State<_NoHardwareWarningDialog> createState() =>
      _NoHardwareWarningDialogState();
}

class _NoHardwareWarningDialogState extends State<_NoHardwareWarningDialog> {
  late int _remaining = widget.waitSeconds;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_remaining <= 1) {
        t.cancel();
        setState(() => _remaining = 0);
      } else {
        setState(() => _remaining -= 1);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canContinue = _remaining == 0;

    return PopScope(
      canPop: false, // 返回键不可退，必须显式选择
      child: AlertDialog(
        icon: Icon(Icons.gpp_maybe, color: theme.colorScheme.error, size: 36),
        title: const Text('无硬件加密保护'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '本设备没有可用的硬件加密方案（TEE / 安全芯片 / 系统密钥库）。',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            _RiskLine(
              text: '若选择「继续」，凭证将以**软件加密**保存在本机——'
                  '加密密钥无硬件保护、与密文并存，能读取本应用私有目录者'
                  '（如已 root、备份导出、取证）可解出，其保密性接近明文。',
            ),
            const SizedBox(height: 8),
            _RiskLine(
              highlight: true,
              text: '这其中包括可访问你全部校园服务的**主凭证（SSO 母凭证）**——'
                  '它同样会以未受硬件保护的形式存于本机。',
            ),
            const SizedBox(height: 12),
            Text(
              '若选择「取消」，凭证只在本次运行内有效、不落盘，退出应用后需重新登录。',
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context)
                .pop(SoftwareStorageChoice.cancelMemoryOnly),
            child: const Text('取消（仅本次有效）'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              foregroundColor: theme.colorScheme.onError,
            ),
            onPressed: canContinue
                ? () => Navigator.of(context)
                    .pop(SoftwareStorageChoice.continueWithSoftware)
                : null,
            child: Text(canContinue ? '仍然继续' : '仍然继续（$_remaining）'),
          ),
        ],
      ),
    );
  }
}

/// 简易「**粗体**」标记渲染，用于风险文案里的重点词。
class _RiskLine extends StatelessWidget {
  const _RiskLine({required this.text, this.highlight = false});

  final String text;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyMedium?.copyWith(
      color: highlight ? theme.colorScheme.error : null,
      height: 1.4,
    );
    final bold = base?.copyWith(fontWeight: FontWeight.bold);

    final spans = <TextSpan>[];
    var rest = text;
    while (true) {
      final start = rest.indexOf('**');
      if (start == -1) {
        spans.add(TextSpan(text: rest));
        break;
      }
      final end = rest.indexOf('**', start + 2);
      if (end == -1) {
        spans.add(TextSpan(text: rest));
        break;
      }
      if (start > 0) spans.add(TextSpan(text: rest.substring(0, start)));
      spans.add(TextSpan(text: rest.substring(start + 2, end), style: bold));
      rest = rest.substring(end + 2);
    }
    return Text.rich(TextSpan(style: base, children: spans));
  }
}
