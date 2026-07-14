/// H 档 TEE/SE 无法解密时的提示（抹除凭证后回到登录）。
///
/// 🔒 红线 #1 相关 UX：不展示任何凭证值；只说明须重新登录。
library;

import 'package:flutter/material.dart';

/// 阻塞提示：硬件密钥库无法解开已存凭证。
Future<void> showHardwareUnlockFailedDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      icon: Icon(
        Icons.lock_reset,
        color: Theme.of(ctx).colorScheme.error,
        size: 36,
      ),
      title: const Text('无法恢复已保存的凭证'),
      content: const Text(
        '设备硬件密钥库（TEE / 安全芯片）无法解密本机已存凭证——'
        '可能因系统升级、恢复出厂、安全芯片重置或数据损坏。\n\n'
        '已清除相关本地凭证，请重新登录校园账号。',
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}
