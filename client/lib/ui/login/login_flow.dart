/// 登录流程编排（复用）：推 [WebViewLoginPage] → 收割写入 store → 刷新会话。
///
/// 开始面板与设置页共用本入口。凭证收割在核心（[WebViewLoginPage] + core/login），
/// 本文件只做导航与状态刷新，**不接触凭证值**（红线 #1）。
library;

import 'package:flutter/material.dart';

import '../../catalog/schools.dart';
import '../../session/session_controller.dart';
import '../security/no_hardware_warning_dialog.dart';
import 'webview_login_page.dart';

/// 发起某校登录；成功则刷新会话并返回结果。调用方据返回值提示用户。
Future<WebViewLoginResult?> runSchoolLogin(
  BuildContext context,
  SessionController session,
  SchoolDescriptor school,
) async {
  // §2.8：首次持久化前确保存储后端就绪。无硬件加密 → 弹警告框（5 秒 + 知情同意）
  // 选 S 软件档或 M 内存档。凭证收割须写入已定档的 store。
  await session.ensurePersistentStore(
    confirmSoftwareFallback: () async {
      if (!context.mounted) return false;
      final choice = await showNoHardwareWarningDialog(context);
      return choice == SoftwareStorageChoice.continueWithSoftware;
    },
  );
  if (!context.mounted) return null;

  final result = await Navigator.of(context).push<WebViewLoginResult>(
    MaterialPageRoute(
      builder: (_) => WebViewLoginPage(
        login: school.login,
        store: session.store,
        debugLog: session.debugLog,
        tlsProceedHosts: school.tlsProceedHosts,
      ),
    ),
  );

  if (result?.status == WebViewLoginStatus.success) {
    session.onCredentialsChanged();
    await session.flush(); // S 软件档：确保收割结果落盘
  }
  return result;
}

/// 把登录结果映射为用户可读提示。
String loginResultMessage(WebViewLoginResult? result, SessionController session) {
  return switch (result?.status) {
    WebViewLoginStatus.success =>
      '登录成功！已收割 ${session.credentialCount} 条凭证',
    WebViewLoginStatus.cancelled => '已取消登录',
    WebViewLoginStatus.error => '登录失败：${result?.error ?? "未知错误"}',
    null => '未完成登录',
  };
}
