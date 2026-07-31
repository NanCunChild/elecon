# ADR-024 落地计划：信任 profile 解绑优化等级

> **状态**：owner 四问已勾决（2026-07-31，见 [`adr_024_build_profile_trust.md`](../adr/adr_024_build_profile_trust.md) §5）；分片落地中。
> 🔒 触红线 #4（DEPLOY 无侧载入口 / dev 传输仅 debug）。判别器翻转、编译期剔除、gate 断言属安全承重，**AI 起草、须人工主导 + 安全清单 + ≥1 人工审，不得 AI 独自闭环**（AGENTS.md §1 / ADR-024 §3）。

本文把 ADR-024 从「已接受 + 开放问题勾决」推到可审代码。**核心纪律：判别器翻转与四条护栏必须同一 PR 捆绑落地**——任何只落一半的中间态（如「优化版已能侧载，但 applicationId / 水印 / gate 未跟上」）都是比现状更危险的产物，禁止合并。

## 0. 勾决答复（对照 ADR §5）

| 问 | 答复 | 落点 |
|---|---|---|
| §5.1 profile 清单 | **仅 DEPLOY + DEV**，无第三个 `UX` | §2.2 矩阵即最终 |
| §5.2 flag 命名 | **`ELECON_TRUST_PROFILE`（值枚举）**，`dev-sideload` ⟹ DEV，余 ⟹ DEPLOY | 基座已落 `trust_profile.dart` |
| §5.3 gate 断言 | **二者并用**：产物符号 grep + 构建元数据标记 | slice 3 改 `check_release_gate.sh` |
| §5.4 水印 | **启动页警告**（不可关，"DEV-SIDELOAD · 不可分发"） | slice 2 |

## 1. 分片

### slice 0 · 纯基座（**已落地，2026-07-31**）

- `client/lib/core/trust/trust_profile.dart`：编译期常量 `kTrustProfile` / `kSideloadEnabled`，fail-closed 默认 DEPLOY（护栏 1、护栏 2 的编译期常量形态）。**尚未接线**，不改任何现有行为。
- `client/test/trust_profile_test.dart`：钉死「缺省 / 未识别 ⟹ DEPLOY」。
- 风险：极低（additive，无 rewire）。可独立合并。

### slice 1 · 判别器翻转（🔒 红线 #4 承重，人工主导）

把侧载判别器从优化等级换到 profile flag：

- `client/lib/core/trust/trusted_context.dart`：`TrustedAdapterContext.devSideload()` 的守卫由 `kDebugMode` 改为 `kSideloadEnabled`；`fetchTrustPermitted` 的 `debugBuild` 语义相应改为「侧载 profile 是否启用」（DEV profile 优化构建也应放行侧载 imperative）。
- **不动传输底座**（ADR §2.4）：dev 传输闸门恒 `kDebugMode`-only，本片不碰。
- 复核点：穷尽 switch 不设 default 的纪律保留；official 路径无变化；DEPLOY 下 `kSideloadEnabled==false` 使 `devSideload()` 首行恒抛、返回分支死代码剔除（与现状同构，只换判别常量）。
- 负例单测：DEPLOY（默认）下 `fetchTrustPermitted(devSideload)` 为 false。

### slice 2 · applicationId 隔离 + 启动页水印（护栏 3）

- Android：DEV 构建用独立 `applicationId` 后缀（如 `…devsideload`），结构上不能覆盖正牌 app、不能作正牌提交。构建矩阵（flavor / dart-define 联动）须保证 DEV ⟺ 后缀 ⟺ `ELECON_TRUST_PROFILE=dev-sideload` 三者一致。
- 启动页：`kSideloadEnabled` 为真时渲染不可关闭警告条（"DEV-SIDELOAD · 不可分发"）。仅 DEV 编入，DEPLOY 下整段 tree-shake。
- iOS 侧对应隔离（bundle id 后缀）按需跟上（ADR-010 商店提交必为 DEPLOY）。

### slice 3 · gate 机械断言（护栏 4，二者并用）

`client/tool/check_release_gate.sh` 增断言，分发 / 提交产物必须是 DEPLOY：

- **(a) 产物符号 grep**：release 产物中侧载入口符号已被剥离（命中即失败）——直接验「代码确实不在产物里」，最强、结构性。
- **(b) 构建元数据标记**：构建注入的 profile 标记必须为 DEPLOY——防符号 grep 因混淆 / 重命名漏网。
- 任一不满足即 `fail`。与现有 INTERNET 权限断言并列。

### slice 4 · 红线 #4 措辞同步（红线改动，owner 决策）

- AGENTS.md 红线 #4「release 包内无侧载入口」→「**DEPLOY profile 包内无侧载入口**（判别器 = 信任 profile flag，fail-closed 默认 DEPLOY）」；「dev 传输只在 debug build 存在」逐字保留。
- ADR-002 §2.5 增一节记本次判别器换位。
- 属红线原文改动，**人工 owner 决策落地**，不由本轨自动改。

## 2. 合并约束

- **slice 1–3 必须捆绑同一 PR**（或同一批、互为前置、一起过审）；slice 0 可先行，slice 4 是红线文案由 owner 单独定。
- 每片 PR 声明遵循 ADR-024 §2.3 四护栏；gate 断言纳入 CI。
- 安全清单：DEPLOY 产物验无侧载符号（slice 3 自动）+ 人工确认 DEV applicationId 隔离 + 启动页水印不可关 + fail-closed 默认（slice 0 单测）。

## 3. 修订记录

| 日期 | 内容 |
|---|---|
| 2026-07-31 | 初版：四问勾决落点；slice 0 纯基座已落地；slice 1–4 待人工主导。 |
