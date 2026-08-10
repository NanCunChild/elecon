/// DEV 侧载产物的启动页水印（ADR-024 §2.3 护栏 3 / §5.4）。
///
/// **它补的是被亲手拆掉的护栏**：ADR-024 之前，「能侧载」等价于「debug 构建」，而
/// debug 的卡顿本身就是一眼可辨的信号——拿到包的人不会误以为它可发布。判别器换成
/// 信任 profile 后，DEV 产物同样是 `--release` 优化构建，这个天然信号消失了。故用
///   ① 独立 applicationId 后缀（`android/app/build.gradle.kts`，结构性防线）
///   ② 本文件的启动页警告（人眼防线）
/// 两者叠加把它换形式装回。
///
/// **形态选择（§5.4 owner 勾决）**：启动页警告，**不是**运行时常驻角标 / 顶部条。
/// 理由：每次冷启动强制可见，且不侵占运行时布局。
///
/// **"不可关闭" 如何落实**：本组件不提供任何关闭 / 隐藏 / 静默入口，也不读任何偏好；
/// 同时启动页有 [devSideloadStartupDwell] 的**最小停留**——否则 bootstrap 极快时警告
/// 会一闪而过，"强制可见" 就成了空话。停留期与 bootstrap 并行，不额外拖慢启动。
///
/// **文案刻意不入 l10n**：这是安全标记而非产品文案，各语言下必须逐字一致、可被人和
/// 脚本一眼识别；进 ARB 反而会带来「某语言漏译 ⟹ 警告消失」的失效模式。
///
/// **DEPLOY 下整体消失**：本文件的唯一调用点被 `if (kSideloadEnabled)`（编译期常量）
/// 包住，DEPLOY 构建里作为死代码被 tree-shake 剔除——连同 [kSideloadEntryMarker]
/// 字面量，`tool/check_release_gate.sh` 的符号断言据此判定。
///
/// 🔒 红线 #4 护栏件：改动本文件须人工 + 安全清单复核（AGENTS.md §1 / ADR-024 §3）。
library;

import 'package:flutter/material.dart';

import '../../core/trust/trust_profile.dart'
    show kBuildProfileLabel, kSideloadEntryMarker;

/// 水印文案（ADR-024 §5.4 逐字）。不本地化——见文件头。
const String kDevSideloadWatermarkText = 'DEV-SIDELOAD · 不可分发';

/// 启动页警告的最小停留时长。与 bootstrap **并行**，故只在 bootstrap 更快时才实际
/// 延长启动；取 1.5s 是「足够被看见」与「不惹恼开发者」的折中。
const Duration devSideloadStartupDwell = Duration(milliseconds: 1500);

/// DEV 侧载产物的启动页。无任何关闭控件——这是刻意的（见文件头）。
class DevSideloadStartupWarning extends StatelessWidget {
  const DevSideloadStartupWarning({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF7F1D1D),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              key: const ValueKey(kSideloadEntryMarker),
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.warning_amber_rounded, size: 64, color: Colors.white),
                SizedBox(height: 24),
                Text(
                  kDevSideloadWatermarkText,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
                SizedBox(height: 16),
                Text(
                  '本构建启用了未签名 adapter 侧载入口（ELECON_TRUST_PROFILE='
                  'dev-sideload）。仅供开发者本机使用，不得分发、不得提交商店、'
                  '不得用于真实账号。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white, fontSize: 14, height: 1.5),
                ),
                SizedBox(height: 24),
                Text(
                  'BUILD PROFILE: $kBuildProfileLabel',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                SizedBox(height: 32),
                SizedBox(
                  width: 160,
                  child: LinearProgressIndicator(
                    color: Colors.white,
                    backgroundColor: Colors.white24,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
