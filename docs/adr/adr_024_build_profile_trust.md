# ADR-024：信任 profile 解绑优化等级——侧载判别器从 `kReleaseMode` 改为自定义编译期 flag

- **状态**：**已接受（Accepted）** · 2026-07-23 owner 评审通过（决策面锁定；开放问题见 §5）。触碰红线 #4（仅官方签名加载 / release 无侧载入口 / dev 传输仅 debug）。**修订 [`adr_002`](./adr_002_trust_model.md) §2.5 的侧载判别机制**。按 [AGENTS.md](../../AGENTS.md) §1：侧载编译期剔除 / gate 断言属安全承重，**AI 不得独自闭环**，须人工主导 + 安全清单 + ≥1 人工审。
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
| **DEPLOY** | ✔ | **编译期剔除** | 无 | 终端用户 / 商店提交 |
| **DEV**（含侧载） | ✔ | 编入（未签名 adapter 可跑、含 dev 凭证注入，警告见 ADR-002 §2.5 + 每 `adapterId` 首次确认） | **仍 debug-only（§2.4）** | 仅开发者，**不可分发** |

> profile 清单未终定（是否再设一个无侧载的 `UX` 开发用 profile，见 §5）。

### 2.3 判别器换位的四条护栏（`kReleaseMode` 白送、现须自证）

`kReleaseMode` 是 Flutter 内建、几乎不可能设错；换成项目 flag 后，以下从「自动成立」变「须自证」：

1. **fail-closed 默认**：flag 缺失 / 拼错 / 未识别 ⟹ **一律 DEPLOY（侧载剔除）**。§2.1 的 `_profile == 'dev-sideload'` 缺省 `false` 即满足——写入 ADR 当硬约束。
2. **编译期剔除、非运行时开关**：`kSideloadEnabled` 是编译期常量，DEPLOY 产物内**根本不存在**启用侧载的代码路径，任何运行时 config/env 都翻不开（保红线 #4「release 包内无侧载入口」，语义平移到 DEPLOY）。
3. **applicationId 隔离（补回被删的天然护栏）**：debug 的「卡」本是天然信号——能侧载的包一眼即知不可发布；DEV 变优化后此信号消失、误发/误提交风险陡增。故 DEV 用**独立 applicationId 后缀**（如 `…devsideload`）：**结构上**不能作正牌 app 提交商店、不能覆盖用户机上的正牌 app、显示为另一应用。叠加**常驻不可关水印**（"DEV-SIDELOAD · 不可分发"）。**这不是过度安全——是把亲手拆掉的护栏换形式装回。**
4. **release gate 机械断言**：`tool/check_release_gate.sh` 增一条——提交 / 分发产物必须是 DEPLOY（侧载符号已剥离，验产物 / 构建参数）。以前 `kReleaseMode` 让「提交的必然安全」自动成立，现须机械查。

### 2.4 传输底座仍 `kDebugMode`-only（profile flag 只管 adapter 侧载）

红线 #4 第二句「dev 传输只在 debug build 存在」**保持不变**：本 flag **只解绑 adapter 侧载**。dev 传输底座看**全部流量**，风险量级远高于单个 adapter，应保留最强天然摩擦（卡 = debug）。即：**DEV profile 可跑未签名 adapter，但不启用未签名传输底座**——后者恒 `kDebugMode`-only。

### 2.5 红线 #4 措辞同步（拟）

- 「release 包内无侧载入口」→「**DEPLOY profile 包内无侧载入口**（判别器 = 信任 profile flag，fail-closed 默认 DEPLOY）」。
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
- 本轨只动**编译期判别机制**，不动侧载**运行时语义**（ADR-002 §2.6：非 official 永不触达凭证注入，DEV 下的「允许注入」分支仍与「拒绝」分支同处条件编译，只是条件从 `kReleaseMode` 换 profile flag）。

---

## 5. 开放问题（待评审勾决）

1. **profile 清单终定**：是否需要第三个 profile（如无侧载、供 UI 开发者的 `UX`）？「UX」具体指什么用途？
2. **flag 命名**：`ELECON_TRUST_PROFILE`（值枚举）vs 布尔 `ELECON_SIDELOAD`？倾向前者（可扩多 profile）。
3. **gate 断言的检测手段**：产物符号 grep vs 构建元数据标记 vs 二者并用。
4. **水印形态**：全屏角标 / 顶部条 / 启动页 —— UI 细节，不入契约。
