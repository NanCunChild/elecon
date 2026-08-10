# ADR-024：信任 profile 解绑优化等级——侧载判别器从 `kReleaseMode` 改为自定义编译期 flag

- **状态**：**已接受（Accepted）** · 2026-07-23 owner 评审通过。当前实现仍为 DEPLOY 零本地导入；[ADR-033](./adr_033_production_sideload.md)（**已接受，尚未落地**）把 DEPLOY gate 改为“仅 official 本地导入，devSideload/未签名路径剔除”，须按其 §5 清单同批落地。触碰红线 #4，须人工主导 + 安全清单 + ≥1 人工审。
- **日期**：2026-07-23
- **依赖**：
  - [`adr_002_trust_model.md`](./adr_002_trust_model.md)（§2.5 dev 侧载闸门、§2.6 运行时语义——本文改 §2.5 的**判别器**，不改运行时语义）
  - [`adr_010_ios_appstore.md`](./adr_010_ios_appstore.md)（「无侧载入口」合规论点——提交商店的产物必为 DEPLOY profile）
- **被依赖**：客户端构建配置（flavor 矩阵）；`tool/check_release_gate.sh`（release gate 断言）。
- **适用范围**：**侧载能力的编译期判别机制**与构建 profile 矩阵。**不含**：侧载运行时语义（ADR-002 §2.6 不变）、签名 / 分发（ADR-018）、adapter 能力模型（ADR-022/023）。

---

## 1. 背景（Context）

ADR-002 §2.5 把「侧载加载路径编译期剔除」实现为**绑定 `kReleaseMode`**：release（优化）= 无侧载，debug（未优化、卡）= 允许侧载。但**「优化等级」与「信任档」是两个正交轴**，被 `kReleaseMode` 捆成一根——后果：只调 adapter、不动 elecon 核心的**社区开发者**，为了拿侧载被迫忍受 debug 的卡顿。

关键事实：社区开发者只调试 **adapter**，不改核心。故没有理由逼他们用未优化构建。应当**解绑**：让「优化」人人可得，「是否含侧载入口」由一个**显式的信任 profile** 决定。

---

## 2. 决策（Decision，草案）

### 2.1 优化等级 ⊥ 信任 profile；判别器换成自定义编译期 flag

- 引入**编译期信任 profile flag**（如 `ELECON_TRUST_PROFILE`，`--dart-define`），作侧载判别器，**取代 `kReleaseMode`**。
- 机制与现状同构（编译期常量 + tree-shake）：

```dart
const _profile = String.fromEnvironment('ELECON_TRUST_PROFILE'); // 缺省 ''
const bool kSideloadEnabled = _profile == 'dev-sideload';        // 编译期常量
// ...
if (kSideloadEnabled) { /* 侧载加载 + dev 凭证注入分支 */ }       // deploy 下整段被 tree-shake 剔除
```

所有构建均可用 `--release` 拿优化；**是否含侧载入口只由 flag 决定**，不再由优化等级决定。

### 2.2 profile 矩阵

| profile | 优化 | adapter 侧载入口 | dev 传输底座 | 分发对象 |
|---|---|---|---|---|
| **DEPLOY** | ✔ | **当前剔除；按 ADR-033 将编入 official-only 本地导入（待落地）** | 无 | 终端用户 / 商店提交 |
| **DEV-Sideload** | ✔ | 编入（未签名 adapter **全能力调试**，警告见 ADR-002 §2.5 + 每 `adapterId` 首次确认） | **仍 debug-only（§2.4）** | 仅开发者，**不可分发** |

> profile 清单**已终定（2026-07-31 owner）：仅 DEPLOY + DEV，不设第三个 `UX` profile**（§5.1）。

> ADR-033 已从“未签名 declarative 生产侧载”打回重写为“DEPLOY official-only 本地导入 + DEV-Sideload 全能力”，并于 2026-08-10 接受。其落地前，本 ADR 的 DEPLOY 零入口 gate 仍是运行基线。

### 2.3 判别器换位的四条护栏（`kReleaseMode` 白送、现须自证）

`kReleaseMode` 是 Flutter 内建、几乎不可能设错；换成项目 flag 后，以下从「自动成立」变「须自证」：

1. **fail-closed 默认**：flag 缺失 / 拼错 / 未识别 ⟹ **一律 DEPLOY（侧载剔除）**。§2.1 的 `_profile == 'dev-sideload'` 缺省 `false` 即满足——写入 ADR 当硬约束。
2. **未签名路径编译期剔除、非运行时开关**：`kSideloadEnabled` 是编译期常量；DEPLOY 内不得存在 `devSideload` grant、未签名执行或 DEV 凭证放行路径，任何运行时 config/env 都翻不开。ADR-033 若接受，DEPLOY 的 official 本地导入走独立入口并汇入统一 verifier，不能复用此 DEV 开关。
3. **applicationId 隔离（补回被删的天然护栏）**：debug 的「卡」本是天然信号——能侧载的包一眼即知不可发布；DEV 变优化后此信号消失、误发/误提交风险陡增。故 DEV 用**独立 applicationId 后缀**（如 `…devsideload`）：**结构上**不能作正牌 app 提交商店、不能覆盖用户机上的正牌 app、显示为另一应用。叠加**常驻不可关水印**（"DEV-SIDELOAD · 不可分发"）。**这不是过度安全——是把亲手拆掉的护栏换形式装回。**
4. **release gate 机械断言**：提交 / 分发产物必须是 DEPLOY。当前断言全部侧载符号剥离；ADR-033 接受后须改为断言 DEV/未签名路径符号为零，并证明本地入口只调用 official verifier + 在线治理门。

### 2.4 传输底座仍 `kDebugMode`-only（profile flag 只管 adapter 侧载）

红线 #4 第二句「dev 传输只在 debug build 存在」**保持不变**：本 flag **只解绑 adapter 侧载**。dev 传输底座看**全部流量**，风险量级远高于单个 adapter，应保留最强天然摩擦（卡 = debug）。即：**DEV profile 可跑未签名 adapter，但不启用未签名传输底座**——后者恒 `kDebugMode`-only。

### 2.5 红线 #4 措辞同步（拟）

- 「release 包内无侧载入口」→「**DEPLOY 不运行未签名 / 非 official adapter；本地导入若存在，只汇入 official verifier 与吊销门禁**（DEV 判别器 fail-closed 默认 DEPLOY）」。
- 「dev 传输只在 debug build 存在」**逐字保留**（§2.4）。
- ADR-002 §2.5 增一节记本次判别器换位；红线原文（AGENTS.md #4）的更新属红线改动，**人工 owner 决策落地**。

---

## 3. 取舍（Consequences）

**收益**
- 社区 adapter 开发者拿到 release 级性能 + 侧载，摩擦消失；「优化」与「信任」正交、语义清晰。

**代价 / 风险**
- 安全判别器从内建 `kReleaseMode` 移到项目 flag，**失去自动正确性** → 靠 §2.3 四护栏补（尤以 applicationId 隔离 + gate 断言为结构性防线）。
- 优化版侧载包失去「卡 = 不可发布」的天然信号 → applicationId + 水印替代。
- gate 从「自动安全」变「机械查」，须维护断言。

---

## 4. 与其它轨的关系

- **与 ADR-022/023（adapter 轨）无依赖**，可并行开 PR（owner 2026-07-23 分轨决策）。
- 本轨只动**编译期判别机制**，不动侧载**运行时语义**（ADR-002 §2.5/§2.6：DEPLOY 不加载非 official，DEV 下的「允许注入」分支仍与 DEPLOY 的拒绝分支作编译期隔离，只是条件从 `kReleaseMode` 换 profile flag）。

---

## 5. 开放问题——已勾决（2026-07-31 owner）

四项开放问题全部拍板，进入落地。落地拆分与签收见 [`docs/reference/adr_024_landing.md`](../reference/adr_024_landing.md)。

### 5.1 profile 清单终定 → **仅 DEPLOY + DEV**

不设第三个（无侧载、供 UI 开发者的）`UX` profile。UI/UX 开发者用 DEPLOY 即可拿优化，无需独立信任档；多一个 profile 只会扩大 gate/水印/applicationId 的组合面而无对应收益。§2.2 矩阵即最终形态。

### 5.2 flag 命名 → **`ELECON_TRUST_PROFILE`（值枚举）**

采值枚举而非布尔 `ELECON_SIDELOAD`：`String.fromEnvironment('ELECON_TRUST_PROFILE')`，`'dev-sideload'` ⟹ DEV，**其余一切（缺省 `''`、拼错、未识别）⟹ DEPLOY**（§2.3 护栏 1 fail-closed 默认）。虽当前只两档，值枚举保留将来扩档余地且判别语义显式。

### 5.3 gate 断言检测手段 → **二者并用（符号 grep + 构建元数据标记）**

当前 `tool/check_release_gate.sh` 同时校验：**（a）产物符号**——全部侧载入口已剥离；**（b）构建元数据标记**——必须为 DEPLOY。ADR-033 落地时，（a）须重构为多项断言：DEV/未签名 grant 与执行路径为零；DEPLOY 本地入口存在且只汇入 official verifier + 在线治理门。单一哨兵不足以证明此调用关系——如何机械证明该调用关系仍是 ADR-033 §6 的开放问题，须在新 gate 落地前有答案。

### 5.4 水印形态 → **启动页警告**

DEV 产物在**启动页**呈现不可关闭的警告（"DEV-SIDELOAD · 不可分发"），非全屏常驻角标 / 顶部条。启动页警告在每次冷启动强制可见、不侵占运行时布局；叠加 §2.3 护栏 3 的独立 applicationId 后缀构成结构性防误发。UI 细节，不入契约。
