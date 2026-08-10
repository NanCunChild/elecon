# ADR-024 落地计划：信任 profile 解绑优化等级

> **状态**：owner 四问已勾决（2026-07-31，见 [`adr_024_build_profile_trust.md`](../adr/adr_024_build_profile_trust.md) §5）；
> **slice 0–3 代码已落地（2026-08-07），Android 旧零入口产物证据已取（见 §4）；slice 4 已按 2026-08-10 owner 第二轮决策记录双渠道目标。ADR-033 已接受但尚未落地，代码仍为零入口基线。
> 🔒 安全签收未完成——代码落地 ≠ 签收。**
> 🔒 触红线 #4（DEPLOY 不运行未签名 / 非 official；dev 传输仅 debug）。判别器、未签名路径剔除与 gate 断言属安全承重，**AI 起草、须人工主导 + 安全清单 + ≥1 人工审，不得 AI 独自闭环**。

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

### slice 4 · 红线 #4/#5 措辞同步（**已重写并随 ADR-033 接受定稿；实现待 ADR-033 §5 落地**）

- 红线 #4 改为来源无关不变量：DEPLOY 只运行 official；ADR-033 的本地导入只汇入 official verifier + 在线治理门。dev transport 仅 debug 不变。
- 红线 #5 明确 DEV-Sideload 全能力；凭证值仍不离核心、DEV 不可分发。
- ADR-033 已决定退役 C3；落地前现有 validator 与 DEPLOY 零入口实现保持不变。

## 2. 合并约束

- **slice 1–3 原落地保持不变**；ADR-033 已接受，其 DEPLOY official 本地入口、在线治理门与新 gate 必须同批落地，禁止出现“入口已开、治理/gate 未跟上”的中间态。
- 每片 PR 声明遵循 ADR-024 §2.3 四护栏；gate 断言纳入 CI。
- 安全清单：当前仍验 DEPLOY 全部侧载符号为零；ADR-033 落地后改验 devSideload/未签名路径为零 + official 本地入口只连统一 verifier/在线治理门；另人工确认 DEV applicationId 隔离与水印。

## 3. 落地实况（2026-08-07）

slice 1–3 已按 §2「捆绑」约束**同一批**落地，无中间态。逐片实际落点：

### slice 1 · 判别器翻转 —— 已落地

- `client/lib/core/trust/trusted_context.dart`：`TrustedAdapterContext.devSideload()` 的守卫由
  `kDebugMode` 改为 `kSideloadEnabled`；`fetchTrustPermitted` 的具名参数由 `debugBuild`
  **改名**为 `sideloadEnabled`（同名不同义最容易悄悄接错，故连名字一起换）。
- `client/lib/core/adapter_runtime.dart`：生产接线改为 `sideloadEnabled: kSideloadEnabled`。
- **传输底座未动**（§2.4）：`kDebugMode` 的其余用处（dev log、WebView inspector、TLS 放行）逐一
  保留原判别器。
- 测试分两轮（见 §5）：DEPLOY 轮断言 fail-closed 与 `devSideload()` 恒抛；DEV 轮跑侧载路径集成。

### slice 2 · applicationId 隔离 + 启动页水印 —— 已落地（Android）

- `client/android/app/build.gradle.kts`：**从 `dart-defines` 解出** `ELECON_TRUST_PROFILE`，
  DEV ⟹ `applicationIdSuffix = ".devsideload"` + `versionNameSuffix = "-devsideload"`。
  从同一个 dart-define 派生是刻意的——若 gradle 另设开关，「Dart 编入侧载 / applicationId 仍是
  正牌」的组合就可能出现，那正是本护栏要防的产物。
- 同文件生成 `assets/elecon_build_profile.txt`（护栏 4b 的产物级证据，见 §4 的踩坑记录）。
- `client/lib/ui/security/dev_sideload_banner.dart` + `main.dart`：DEV 的启动页即水印页
  （"DEV-SIDELOAD · 不可分发"），无任何关闭/隐藏入口，并有 1.5s 最小停留与 bootstrap 并行
  ——否则 bootstrap 极快时警告一闪而过，"每次冷启动强制可见" 就成了空话。

### slice 3 · gate 机械断言 —— 已落地

`client/tool/check_release_gate.sh` 新增：静态两条（哨兵常量与 Dart 侧一致；侧载守卫未被改回
优化等级）+ 产物两条（4a 符号 grep、4b 元数据标记，缺标记也算失败）。
`check_release_gate_test.sh` 扩为 4 负例 + 1 正例——**正例不可省**：只有负例时，"gate 拒绝一切"
与 "gate 正确" 无法区分。
`release.yml` 新增一步：闸门跑在**真正要分发的那个 APK** 上，而非 CI 另编的一份。

### slice 4 · 红线 #4/#5 措辞 —— 已随 ADR-033 接受定稿，代码待其 §5 落地

文档已区分渠道与信任档：DEPLOY 只运行 official；DEV-Sideload 全能力。当前代码仍是 DEPLOY 零本地入口，
与 ADR-033 目标态的差异已显式记录；其 §5 清单同批落地前，不得单独实现 official 本地导入或单独删除 C3。

## 4. 产物级证据（2026-08-07，本机 Android release 实测）

| 断言 | DEPLOY 构建 | DEV 构建（`--dart-define=ELECON_TRUST_PROFILE=dev-sideload`） |
|---|---|---|
| `applicationId` | `dev.nancunchild.elecon` | `dev.nancunchild.elecon.devsideload` |
| `versionName` | `0.1.0` | `0.1.0-devsideload` |
| 侧载哨兵 `ELECON_SIDELOAD_ENTRY_A7F3` 出现次数 | **0** | 3 |
| `assets/elecon_build_profile.txt` 首行 | `DEPLOY` | `DEV-SIDELOAD` |
| `check_release_gate.sh` | 通过 | **拒绝**（护栏 4a 命中） |

两次构建均为 `--release`（优化），**证实 §2.1 的解绑成立**：优化等级与是否含侧载入口互不牵连。

> **踩坑记录（值得留档）**：护栏 4b 的标记任务最初只声明了 `outputs`、没声明 `inputs`，
> gradle 据此判 UP-TO-DATE，于是**首次 DEV 构建原样留下了上一次 DEPLOY 写的标记**——
> 元数据说 DEPLOY、产物里却有侧载入口。是护栏 4a 的符号 grep 拦下的。
> 这正是 ADR-024 §5.3 坚持「二者并用」的实证：单靠元数据标记会被构建缓存击穿。
> 已通过 `inputs.property` 修复，并双向验证（DEV→DEPLOY 切回也正确失效）。

## 5. 两轮测试 profile（CI）

判别器换位后，「侧载可用」不再等价于「测试在 debug 跑」，故 `ci.yml` 的 client job 跑两轮：

| 轮次 | 命令 | 该轮独有的断言 |
|---|---|---|
| DEPLOY（默认） | `flutter test` | 护栏 1 fail-closed 默认；`devSideload()` 恒抛；启动页**无**水印 |
| DEV | `flutter test --dart-define=ELECON_TRUST_PROFILE=dev-sideload` | 侧载信任票可构造；imperative 运行时集成；启动页**有**水印 |

需侧载票的用例在 DEPLOY 轮 `skip`（带明确理由串），由 DEV 轮真正执行。少任一轮就会留下
未被断言的分支。本机实测：DEPLOY 轮 835 passed / 11 skipped；DEV 轮 844 passed / 2 skipped。

## 6. 仍开放

- **slice 4**：红线 #4 与 ADR-002 §2.5 措辞同步（owner 决策）。
- **非 Android 平台的 applicationId 隔离与产物 gate**：iOS bundle id 后缀、macOS/Windows/Linux
  的 profile 标记与符号断言均未做。当前这些平台靠护栏 1 的 fail-closed 默认（不传 dart-define
  即 DEPLOY）成立，但**没有机械复核**。ADR-010 的商店提交论点因此只在 Android 有产物级证据。
- **人工安全签收**：本轨触红线 #4，AI 不得独自闭环。签收清单见 §2。

## 7. 修订记录

| 日期 | 内容 |
|---|---|
| 2026-07-31 | 初版：四问勾决落点；slice 0 纯基座已落地；slice 1–4 待人工主导。 |
| 2026-08-07 | slice 1–3 落地并取得 Android 产物级证据（§4）；补两轮测试 profile（§5）；记录护栏 4b 的 gradle 缓存踩坑；slice 4 与非 Android 平台仍开放（§6）。安全签收未完成。 |
