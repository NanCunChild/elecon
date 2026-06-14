# ADR-003：传输底座抽象与 VPN 复刻接入（许可证隔离方案）

- **状态**：草案（Proposed） 本文定义传输底座（看到**全部流量**的承重路径，红线 #4/#1）。按 AGENTS.md §1，**AI 不得独自闭环**：本草案由 AI 起草，**必须经人工 + 安全检查清单审阅后才可接受并实现**。
- **日期**：2026-06-12（**修订 2026-06-14**：§2.3 澄清"TLS 不终止 ≠ 禁止隧道封装"——L3/SSL-VPN 嵌套加密天然兼容，仅"本地拆 TLS"触红线 #1；§2.4 协议模式探针增"是否本地终止/拦截 app TLS"一项）（**修订 2026-06-14b（review 跟进 PR #23）**：§2.2 加注 relay 优先为目标态、首版仅 client-direct（对齐 ADR-012 §2.6）；§2.2 降级链补 system-vpn 自身失败分支；§3 增第 7 条 iOS Personal VPN entitlement 可得性"待确认"开放项）
- **依赖**：[`adr_000_abstract.md`](./adr_000_abstract.md)（§3.4 transport/adapter 区分、§5.2 VPN 复刻风险、红线 #4）、[`adr_002_trust_model.md`](./adr_002_trust_model.md)（签名 / 官方签名加载 / 吊销，草案）、[`adr_009_fetch_credential.md`](./adr_009_fetch_credential.md)（`ctx.fetch` 出网经 transport，草案）、[`adr_010_ios_appstore.md`](./adr_010_ios_appstore.md)（iOS 无隧道、GPLv3 分发不相容、指南 5.4）
- **适用范围**：**传输底座（原生模块）**的抽象接口、信任与加载、平台可用性矩阵、atrust VPN 复刻的接入与**许可证隔离**。**不含** adapter 信任分档（ADR-002）、凭证注入/脱敏机制（ADR-009）、UI。

---

## 1. 背景（Context）

ADR-000 §3.4 把**传输底座**（原生、长生命周期、有状态、**承载全部流量**）与数据 adapter（脚本、I/O 密集、热替换无负担）划为两类，走两套信任策略，但只给了方向（`direct / 系统VPN / app内隧道`、"仅官方签名"），没定**抽象接口**与**接入机制**。§5.2 把深信服 atrust 的开源复刻列为"可替换 transport"，已知风险四项：协议私有、上游可能停维（按年更新、频率低）、**许可证 GPLv3**、iOS 上架与后台联网限制；对策是"三件套探针 + 不焊死"。ADR-010 已就 iOS 定调：**不带 App 内隧道、GPLv3 不入 iOS 二进制、改用系统 VPN**。

本文把"transport 抽象 + atrust 接入 + 许可证隔离"落成可执行设计。贯穿全文的三重张力：

> **transport 看到全部流量（最高信任面，红线 #1/#4）× GPLv3 的链接传染与商店分发不相容 × 跨平台不对称（iOS 最严）。**

---

## 2. 决策（Decision，草案）

> 以下为**待审议**取向，非既定事实。每条都需安全审阅确认。

### 2.1 transport 是「窄接口后的可替换原生模块」，不是脚本插件

核心面向一个**实现无关的窄接口**消费 transport（与 adapter 的 QuickJS 路径完全分离，ADR-000 §3.4）：

- **生命周期**：`init / connect / disconnect / dispose`。
- **状态**：`disconnected / connecting / connected / failed` + 可达性/健康探测。
- **路由（唯一数据面职责）**：核心把"**已注入凭证的真实请求**"（ADR-009 §2.1 第 3 步）交给当前 active transport 送达 origin 并回传字节。

约束：

- transport **只搬运字节**——不解析、不碰 schema、不持凭证语义（凭证由 broker 在 HTTP 语义层注入，见 §2.3）。它与 adapter 正交。
- **一次只有一个 active transport** 承载全部流量；可在运行时切换（"热替换无负担"指可替换，**不是**多路并发/分流，见 §3 第 6 条）。

### 2.2 三类传输档（按风险/可用性排序）

| 档 | 形态 | 平台 | 信任 / 分发 | 触及 GPL/entitlement |
|---|---|---|---|---|
| **`direct`** | 无隧道，OS 网络栈直连 | 全平台（默认） | 无额外信任面 | 否 |
| **`system-vpn`** | **引导用户在 OS 层配置 VPN**（iOS `NEVPNManager`/on-demand、Android `VpnService` 系统设置）；隧道在系统/第三方 App，elecon 只发起/检测、**不承载隧道本身** | 全平台（含 iOS） | 无（不分发隧道代码） | iOS 需申请 **Personal VPN entitlement**（门槛远低于 Network Extension，但仍是 entitlement 依赖）；Android/桌面 否 |
| **`app-tunnel`** | **App 内原生隧道**（atrust 复刻属此） | **平台门控**：iOS 默认不编入（ADR-010） | **仅官方签名**加载（红线 #4）、最高信任档 | **是**（唯一触碰档） |

**transport 与 campus relay 的关系（目标架构）**：当 `system-vpn` 或 `app-tunnel` 使客户端处于校园网可达状态时，私密数据请求**优先经 campus relay（`server/src/campus`）中转**；若 relay 不可用则 **fallback 到客户端直连学校 origin**。`direct` 档在校外时无校园网可达性，只能访问公开数据或提示用户。

> **注**：relay 优先是**目标态**。首版（[`adr_012`](./adr_012_credential_store.md) v1）仅 client-direct，relay 落点随本 ADR 接受 + relay 设计成熟后分步实现。凭证存储的接受与实现不依赖 relay（ADR-012 §2.6）。

**降级链（fail-safe，不是 fail-open；有序）**：

1. active transport 为 `app-tunnel` 且失败 → **尝试 `system-vpn` 引导**（提示用户配置/连接系统 VPN）；
2. active transport 为 `system-vpn`（或经 step 1 引导后）且失败/不可用/用户跳过 → **降级到只读公开缓存**（ADR-000 §3.4），仅展示已缓存的公开数据；
3. **显式提示用户**：当前无法访问私密数据，需连接校园网或配置 VPN，由用户决定下一步。

> 即：`app-tunnel → system-vpn → 只读公开缓存`；若起点即为 `system-vpn`，失败后直接降到只读。任何降级步骤**绝不**静默改路由为明文直连。

**关键不变量：失败绝不静默改路由成明文直连**——本应走隧道的私密流量不得因 transport 故障而裸奔出校园网边界。

### 2.3 安全不变量：transport 看全部流量 → 最高信任 + 永不见凭证明文

- **仅官方签名 transport 可加载**（红线 #4；二进制签名/验签见 ADR-002 §2.3）；**dev transport 仅 debug build**；**release 无侧载入口**。
- **transport 不得终止 / 中间人 TLS。** 分层澄清：broker 在 **TLS 之上的 HTTP 语义层**构造请求并注入凭证（ADR-009）→ TLS 由核心/OS 的 TLS 栈完成 → **密文字节**才交给 transport 搬运。transport 处于 TLS 之下，**天然只见密文**；它**不得**解密、注入根证书或 MITM。否则它即可窥见 broker 注入的凭证明文，直接打穿红线 #1。**凭证明文永不出现在 transport 可见层**——这是本档最高信任门槛之外的硬技术约束。

- **"不终止"≠"禁止隧道封装"（2026-06-14 澄清，回应"部分 VPN 是否支持"的疑问）。** 本不变量约束的是**我方签名加载的 transport 模块不做 MITM**，**不**禁止嵌套加密。绝大多数 VPN 天然兼容：
  - **L3 包隧道**（WireGuard / IPSec / OpenVPN / 系统 VPN）：只转发 IP 包，app 的 TLS 端到端到 origin，隧道只见密文 → **兼容**。
  - **SSL-VPN 隧道**（atrust / EasyConnect 这类）：其 "SSL" 指**外层隧道**，把整条 TCP/IP 流**封装**进外层 SSL 后转发到校内网关，**内层 app TLS 仍端到端**、无人解密 → **兼容**（嵌套加密，非终止）。
  - **真正冲突的只有两类**，均默认禁止 / 须单独评估：① 我方 transport 在**客户端本地拆 TLS**（起本地代理、装根证书重签）→ 直接打穿红线 #1，**绝对禁止**；② 第三方网关被配成 **SSL-inspection（解密内层）模式** → 超出我方控制但意味着凭证在网关可见，须在 §2.4 探针识别。
  - 一句话：**封装式 VPN（含 SSL-VPN）不触本不变量；只有"本地终止/拦截 app TLS"才触。**
- **不持私密状态落公网**（红线 #2）：app-tunnel 的会话/握手状态只在客户端或校内授权环境，绝不经 `server/src/public`。
- **吊销 + kill-switch**：transport 二进制纳入 ADR-002 §2.4 吊销清单；可吊销某 transport 版本，核心据此降级到 `direct`/`system-vpn`（fail-safe）。

### 2.4 atrust VPN 复刻的接入 = 三件套探针先行（gate）

延续 ADR-000 §5.2"不焊死 + 开工前探针"，**未过探针不进实现**：

1. **许可证探针**：确认复刻的确切 license（GPLv3？有无链接例外？）、作者是否愿独立/双授权。
2. **协议模式探针**：协议稳定度（按年变更）、复刻完成度、能否在 user-space 网络栈实现（决定可移植性）；**并显式确认该客户端是"纯隧道封装"还是会"本地终止 / 拦截 app TLS"**（§2.3）——若属后者即触红线 #1，按 §3.4 走单独 ADR + 安全评审，默认不上。
3. **iOS 可行性探针**：`NetworkExtension` entitlement 可得性 + GPLv3 分发（ADR-010 已判**不相容**）→ 预期结论：**iOS 不上 app-tunnel**。

接入形态：作为 §2.1 抽象下的**一个 `app-tunnel` 实现**，坏了/上游停维即切回 `direct`/`system-vpn`，不焊死。

### 2.5 许可证隔离方案（GPLv3，本文核心难点）

把两个常被混淆的问题分开（ADR-010 §2.3 已点明，这里给落地）：

- **① 链接传染**：GPL 代码静态/动态链进主二进制 → 主程序被传染。**隔离手段：进程边界 / 独立分发单元 + 窄 IPC**——GPL 实现跑在单独进程或单独可分发组件里，主 App 经 IPC 调用，不链接其符号。
- **② 商店分发相容性**：GPLv3 与 App Store DPLA 使用限制不相容（VLC 案例）。**进程隔离治不了这一层**——只要 GPL 二进制随**官方商店渠道**分发即冲突。

据此**分平台定策**：

| 平台 | `app-tunnel`(GPL) 可行性 | 形态 |
|---|---|---|
| **iOS / App Store** | **不可**（分发不相容 + entitlement 门槛） | 不编入；`direct` + `system-vpn` |
| **Android**（Play / 侧载） | 可，但须履行 GPLv3 §6：提供对应源码、不附加限制 | 独立进程 sidecar / 独立分发组件（独立 APK 或 Service）+ 窄 IPC |
| **桌面** | 类 Android，按各自商店规则 | 同上 |
| **OHOS** | 开发优先级低，待后续确认；若 Flutter 无法覆盖 OHOS 的 VPN/隧道 API，再考虑独立技术栈与 QuickJS FFI 方案 | 暂同桌面；具体形态待定 |

**三条根本出路**（与 ADR-010 §2.3 一致，按建议排序）：

1. **默认：官方分发的二进制不带 GPL transport**；`system-vpn` 引导全平台兜底（首选，零法律面）。
2. **clean-room 以相容许可证重写** atrust 协议客户端——**唯一**能让 in-app tunnel 上 iOS 的路径；成本最高，按需求强度决定。
3. **取得独立/双授权**，或把 GPL transport 作为**用户自行安装的独立组件**（不随官方包分发，用户侧 sideload，类比引导安装官方 atrust 客户端）。

**结论取向**：**首版只做 `direct` + `system-vpn`**（全平台、零 GPL/entitlement 风险）；`app-tunnel` 作为后续、平台门控、经三件套探针、以"进程隔离 + 平台分发矩阵"分别处理的**可选档**。

---

## 3. 已知约束与风险（Consequences，草案）

1. **承重 + 最高信任面（红线 #4/#1）。** transport 看全部流量，实现与测试**不得 AI 独自闭环**；需安全检查清单 + 人工审阅（git.md §3：`transport`/签名属最严档）。
2. **GPL 是法律面，非工程可独断**（ADR-010 §3.4）。clean-room / 授权 / §6 源码合规须法务确认；本文不构成法律意见。
3. **`system-vpn` 的可用性代价。** 依赖用户操作 + 系统/第三方 VPN 可用性，校外体验不如 app-tunnel 顺滑——已接受的代价（与 ADR-000 §5.2 校外天花板、ADR-010 §3.5 跨平台不对称一致）。
4. **"TLS 不终止"是硬不变量。** 若未来某 transport 需要看明文（如协议改写），即触碰红线 #1，**必须单独 ADR + 安全评审**，默认禁止。
5. **跨平台能力不对称**（iOS 最弱）带来产品文案/预期管理成本。
6. **单 active transport；split-tunnel 不在本文。** 按域名分流（部分走隧道、部分直连）会放大"路由错配致私密流量裸奔"的风险（§2.2 不变量），留待单独评估。
7. **🔲 待确认（接受前）：iOS Personal VPN entitlement 可得性。** `system-vpn` 档在 iOS 依赖 **Personal VPN entitlement**（`NEVPNManager`）。其门槛远低于 Network Extension，但仍是一项 entitlement 依赖，且 [ADR-010](./adr_010_ios_appstore.md) 未就此评估。**取向**：标注"待确认"即可接受本 ADR——若该 entitlement 因审核策略不可得，iOS 的 `system-vpn` 引导退化为"提示用户在系统设置自行配置 VPN"（纯引导、零 entitlement），不阻塞 `direct` 档与本 ADR 主体。须在 iOS 上架评估（§4 / ADR-010 §3.3）时一并确认。

---

## 4. 落地清单（待 ADR 接受后，拆成可审查的小 PR）

> 安全敏感项标（人工主导、AI 仅辅助）：

- **transport 抽象接口（核心侧）**：lifecycle/status/routing 窄接口；单 active + 运行时切换 + 降级链；**TLS 不终止**不变量落为代码约束。客户端与（如适用）`server/src/campus` 对齐。
- **加载与信任**：transport 二进制验签（ADR-002）+ 吊销/kill-switch + dev-only 侧载闸门 + **平台 build flag**（iOS 不编入 `app-tunnel`）。
- **`direct` / `system-vpn` 两档先行**：`direct` = OS 网络；`system-vpn` 经 `NEVPNManager`(iOS)/`VpnService`(Android) 引导 + 可达性检测 + 降级。
- **三件套探针（atrust）**：许可证 / 协议模式 / iOS 可行性，产出 go/no-go 文档，未过不进实现。
- **许可证隔离（若上 `app-tunnel`）**：进程/独立分发边界 + IPC 规格；GPLv3 §6 源码合规；按 §2.5 平台分发矩阵执行。
- **契约（如需，独立 ADR）**：envelope `source.origin` 增 transport 维度（如 `client-direct` 经 direct/tunnel），与 ADR-001/009 协调、向后兼容。
- **测试**：transport 状态机/降级链单测；**TLS-不终止**断言；签名/吊销正反例；不在 UI 线程阻塞（红线 #7 同源精神，原生侧勿阻塞主线程）。
