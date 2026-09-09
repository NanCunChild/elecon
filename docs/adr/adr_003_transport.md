# ADR-003：传输底座抽象与 VPN 复刻接入

- **状态**：已接受（Accepted） 本文定义传输底座（看到**全部流量**的承重路径，红线 #1）。按 AGENTS.md §1，**AI 不得独自闭环**：本文由 AI 起草，经人工 review（PR #23）+ 安全检查清单审阅后接受。
- **日期**：2026-06-12（**修订 2026-06-14**：§2.3 澄清"TLS 不终止 ≠ 禁止隧道封装"——L3/SSL-VPN 嵌套加密天然兼容，仅"本地拆 TLS"触红线 #1；§2.4 协议模式探针增"是否本地终止/拦截 app TLS"一项）（**修订 2026-06-14b（review 跟进 PR #23）**：§2.2 加注 relay 优先为目标态、首版仅 client-direct（对齐 ADR-012 §2.6）；§2.2 降级链补 system-vpn 自身失败分支；§3 增第 7 条 iOS Personal VPN entitlement 可得性"待确认"开放项）（**修订 2026-07-24（讨论澄清，AI 起草待人工审）**：新增 §2.6 区分「包级隧道」与「应用层代理隧道」——后者用户态网络栈、不建 TUN、不进内核、不占系统唯一 VPN 槽，南向标准 SOCKS/HTTP、北向对网关仅一条标准 TLS:443（私有协议封在载荷内），**不触 iOS NetworkExtension / entitlement / 指南 5.4**；据此修订 §2.2 平台矩阵对 `app-tunnel` 的 iOS 判定。**净室与否、以及嵌入形态 FFI vs 本地回环仍为开放问题**，见 §2.6 末，须子 ADR + 人工主导）
- **2026-09-09 修订（owner 决策）**：① §2.1 「单 active transport 承载全部流量」→ **每请求单通道**（与 §2.6 形态 B 的冲突以 §2.6 为准），§3.6 同步改写；② §2.3 **transport 签名/验签/吊销清单作废**——transport 编译期编入二进制，无加载门，改为编译期门控 + **远程开关**，AGENTS.md 红线 #4 中关于 transport 的部分随之作废；③ §2.5 标的定为 **Hermes（MIT）**，GPL 隔离矩阵[归档](../archive/adr_003_gpl_isolation_superseded.md)，**iOS 重新纳入**；④ 新增 §2.1.1 明确 adapter 对通道「不选、不知」，并把「核心据什么判定通道」列为**显式未决**。
- **依赖**：[`adr_000_abstract.md`](./adr_000_abstract.md)（§3.4 transport/adapter 区分、§5.2 VPN 复刻风险）、[`adr_002_trust_model.md`](./adr_002_trust_model.md)（§2.4 远端治理面 / kill-switch）、[`adr_009_fetch_credential.md`](./adr_009_fetch_credential.md)（`ctx.fetch` 出网经 transport）、[`adr_010_ios_appstore.md`](./adr_010_ios_appstore.md)（iOS 分发）、[`adr_032`](./adr_032_app_tunnel_embedding.md)（`app-tunnel` 嵌入形态，Proposed）
- **适用范围**：**传输底座（原生模块）**的抽象接口、信任与加载、平台可用性矩阵、atrust VPN 复刻的接入与**许可证隔离**。**不含** adapter 信任分档（ADR-002）、凭证注入/脱敏机制（ADR-009）、UI。

---

## 1. 背景（Context）

ADR-000 §3.4 把**传输底座**（原生、长生命周期、有状态、**承载全部流量**）与数据 adapter（脚本、I/O 密集、热替换无负担）划为两类，走两套信任策略，但只给了方向（`direct / 系统VPN / app内隧道`、"仅官方签名"），没定**抽象接口**与**接入机制**。§5.2 把深信服 atrust 的开源复刻列为"可替换 transport"，已知风险四项：协议私有、上游可能停维（按年更新、频率低）、**许可证**、iOS 上架与后台联网限制；对策是"三件套探针 + 不焊死"。

> **2026-09-09 更新**：三件套探针已完成（[`probe_002`](../probes/probe_002_atrust_tunnel.md)，判定 go 附条件），**许可证一项已消解**——标的 Hermes 自有 MIT。ADR-010 早先「不带 App 内隧道、GPLv3 不入 iOS 二进制」的定调**仅适用于 GPL 标的 + 形态 A**，已随 §2.5/§2.6 修订。

本文把"transport 抽象 + atrust 接入 + 许可证隔离"落成可执行设计。贯穿全文的三重张力：

> **transport 看到全部流量（最高信任面，红线 #1）× 标的许可证 × 跨平台不对称（iOS 最严）。**
>
> 第二项已于 2026-09-09 消解（标的 MIT，§2.5）；本文保留该框架是因为它仍是选型时的判据顺序。

---

## 2. 决策（Decision）

> 以下为**待审议**取向，非既定事实。每条都需安全审阅确认。

### 2.1 transport 是「窄接口后的可替换原生模块」，不是脚本插件

核心面向一个**实现无关的窄接口**消费 transport（与 adapter 的 QuickJS 路径完全分离，ADR-000 §3.4）：

- **生命周期**：`init / connect / disconnect / dispose`。
- **状态**：`disconnected / connecting / connected / failed` + 可达性/健康探测。
- **路由（唯一数据面职责）**：核心把"**已注入凭证的真实请求**"（ADR-009 §2.1 第 3 步）交给**该请求选定的 transport** 送达 origin 并回传字节（通道由核心逐请求裁定，见下）。

约束：

- transport **只搬运字节**——不解析、不碰 schema、不持凭证语义（凭证由 broker 在 HTTP 语义层注入，见 §2.3）。它与 adapter 正交。
- **每请求单通道 + 禁止静默降级（2026-09-09 修订，取代原「一次只有一个 active transport 承载全部流量」）。**
  真正的不变量是：**每一个出站请求，其通道由核心在发出前唯一确定；失败绝不回退到更弱的通道**（§2.2 末）。
  「单 active」曾是这条不变量的粗糙代言，它默认了**形态 A**（包级隧道接管 OS 路由 → 天然唯一）；
  §2.6 引入的**形态 B**（应用层代理隧道）**不建 TUN、不改 OS 路由、只承载显式经它 dial 的流量**，
  即天生分流，「承载全部流量」对它**事实上不成立**。以 §2.6 为准。
  - 因此**允许多个 transport 实例并存**：多校各自的校内可达性、campus relay 与 tunnel 并用、
    公开数据（`notice.list` 之类）走 `direct` 而不浪费隧道，都是正当形态。
  - 形态 A 仍然唯一，但那是**平台约束**（占系统唯一 VPN 槽），不是本文的架构规则。
  - 通道由核心按**可达性需求**选定，**adapter 无从选择、也无从得知**（见 §2.1.1）。

#### 2.1.1 adapter 与通道的关系：**adapter 不选、不知**（决策）；**核心怎么判**（未决）

**已决（本文不变量）**：

- **adapter 不得选择通道。** 若 adapter 能要求「走隧道」，它就在自决自己的网络可达性——正是红线 #5
  约束的能力面；一个侧载 adapter 借此拿到校内可达性即是安全事故。**通道由核心裁定。**
- **adapter 不得知晓当前通道。** 外部 VPN、`system-vpn`、我方 `app-tunnel` 在 adapter 眼里**必须完全
  一致**（`ctx.fetch` 行为相同）。这是**设计目标不是缺口**：首版发 `direct` + 引导用户用外部 VPN，
  将来加 `app-tunnel`，**adapter 一行都不用改**——adapter 永不为传输层演进买单。
- **「用户是否装了外部 VPN」无法查询，只能探测。** iOS / Android 均无 API 告知「某第三方 VPN 已连接
  且路由了校内网段」。故机制只能是**可达性探测**，其产物是一个**与 transport 无关**的观测量
  （校内目标当前可达 / 不可达），外部 VPN、`system-vpn`、`app-tunnel` 三者在该观测量下统一。
- **差别要告诉用户，不是告诉 adapter。** 走第三方网关时，若网关被配成 SSL-inspection 模式，
  **凭证在网关可见**（§2.3「真正冲突的两类」之②）——红线 #1 的保证强度下降且不由我方控制。
  这属于**须对用户可见的安全态**，不进 adapter 可见面。

**未决（须独立 ADR，🔒 人工主导）**：核心据什么判定「这个请求该走哪条通道」。

当前行为是**没有判定**：校外跑校内 adapter 就是干等超时，语义模糊，且可能在跳转 captive portal 的
过程中白白动用凭证。已提出但**尚未决策**的方向是让 manifest 声明**可达性要求**（如
`network.allow[].reachability: "public" | "campus"`，缺省 `public`）——它是**关于学校端点的事实陈述**，
不是 adapter 的选择权；核心在分派 capability **之前**判定，要求 campus 而不可达即结构化失败
（**请求不发出、凭证不解析**），UI 提示「需连校园网 / VPN」。

该方向触**契约**（红线 #6）与**能力面**（红线 #5），**必须先有独立 ADR**，本文不预先批准。
在它落地前，§2.1「每请求单通道」的判据缺一个可审的输入，§3.6 的残余风险相应存在。

### 2.2 三类传输档（按风险/可用性排序）

| 档 | 形态 | 平台 | 信任 / 分发 | 触及 GPL/entitlement |
|---|---|---|---|---|
| **`direct`** | 无隧道，OS 网络栈直连 | 全平台（默认） | 无额外信任面 | 否 |
| **`system-vpn`** | **引导用户在 OS 层配置 VPN**（iOS `NEVPNManager`/on-demand、Android `VpnService` 系统设置）；隧道在系统/第三方 App，elecon 只发起/检测、**不承载隧道本身** | 全平台（含 iOS） | 无（不分发隧道代码） | iOS 需申请 **Personal VPN entitlement**（门槛远低于 Network Extension，但仍是 entitlement 依赖）；Android/桌面 否 |
| **`app-tunnel`** | **App 内原生隧道**（Hermes 属此，形态 B） | **全平台可编入**（含 iOS，2026-09-09 修订；旧「iOS 默认不编入」仅适用形态 A + GPL 标的） | **编译期编入 + 远程开关**（§2.3），最高信任档 | **否**（标的自有 MIT，见 §2.5） |

**transport 与 campus relay 的关系（目标架构）**：当 `system-vpn` 或 `app-tunnel` 使客户端处于校园网可达状态时，私密数据请求**优先经 campus relay（`server/src/campus`）中转**；若 relay 不可用则 **fallback 到客户端直连学校 origin**。`direct` 档在校外时无校园网可达性，只能访问公开数据或提示用户。

> **注**：relay 优先是**目标态**。首版（[`adr_012`](./adr_012_credential_store.md) v1）仅 client-direct，relay 落点随本 ADR 接受 + relay 设计成熟后分步实现。凭证存储的接受与实现不依赖 relay（ADR-012 §2.6）。

**降级链（fail-safe，不是 fail-open；有序）**：

1. 该请求选定的通道为 `app-tunnel` 且失败 → **尝试 `system-vpn` 引导**（提示用户配置/连接系统 VPN）；
2. 选定通道为 `system-vpn`（或经 step 1 引导后）且失败/不可用/用户跳过 → **降级到只读公开缓存**（ADR-000 §3.4），仅展示已缓存的公开数据；
3. **显式提示用户**：当前无法访问私密数据，需连接校园网或配置 VPN，由用户决定下一步。

> 即：`app-tunnel → system-vpn → 只读公开缓存`；若起点即为 `system-vpn`，失败后直接降到只读。任何降级步骤**绝不**静默改路由为明文直连。

**关键不变量：失败绝不静默改路由成明文直连**——本应走隧道的私密流量不得因 transport 故障而裸奔出校园网边界。

### 2.3 安全不变量：transport 看全部流量 → 最高信任 + 永不见凭证明文

- **transport 是应用二进制的一部分，不存在加载路径（2026-09-09 修订，取代原「仅官方签名 transport 可加载」）。**
  [`adr_032`](./adr_032_app_tunnel_embedding.md) §2.2 已定**进程内 FFI**：transport 在**编译期**编入产物，
  没有加载期决策，因此**没有可设的加载门**——为它单独签名不增加任何证明，「吊销某个 transport 版本」
  对编译进二进制的模块也不成立（你只能发新版，那叫发版不叫吊销）。其完整性由**平台的应用签名**承担
  （APK / IPA 签名），这与 ADR-002 §2.3 的 Ed25519 **bundle** 验签**不是同一条链路**。
  **AGENTS.md 红线 #4 中关于 transport 的部分据此作废**（owner 决策 2026-09-09）；该红线正文自始只约束
  adapter，编号与内容保留不变。取而代之的三条约束：
  1. **编译期门控**：哪些 transport 档编入哪个平台 / 哪个 build profile，由 build flag 决定（§4）。
     **某些档只在 debug build 编入**这一约束保留（原红线 #4 第二句的实质，见 [`adr_024`](./adr_024_build_profile_trust.md) §3）。
  2. **远程开关（禁用 / 启用）**：transport 档纳入 [`adr_002`](./adr_002_trust_model.md) §2.4 的远端治理面，
     可在**不发版**的前提下禁用或启用某个档，核心据此按 §2.2 降级链退到 `system-vpn` / `direct`（fail-safe）。
     这是**策略开关，不是代码吊销**——被禁用的代码仍在二进制里，只是不被使用。
  3. **transport 不是可侧载物**：DEPLOY 与 DEV 均无 transport 本地导入 / 动态加载入口。
     本条是**防止将来重新引入加载路径**的不变量，不是对现状的描述。
- **transport 不得终止 / 中间人 TLS。** 分层澄清：broker 在 **TLS 之上的 HTTP 语义层**构造请求并注入凭证（ADR-009）→ TLS 由核心/OS 的 TLS 栈完成 → **密文字节**才交给 transport 搬运。transport 处于 TLS 之下，**天然只见密文**；它**不得**解密、注入根证书或 MITM。否则它即可窥见 broker 注入的凭证明文，直接打穿红线 #1。**凭证明文永不出现在 transport 可见层**——这是本档最高信任门槛之外的硬技术约束。

- **"不终止"≠"禁止隧道封装"（2026-06-14 澄清，回应"部分 VPN 是否支持"的疑问）。** 本不变量约束的是**我方编入的 transport 模块不做 MITM**，**不**禁止嵌套加密。绝大多数 VPN 天然兼容：
  - **L3 包隧道**（WireGuard / IPSec / OpenVPN / 系统 VPN）：只转发 IP 包，app 的 TLS 端到端到 origin，隧道只见密文 → **兼容**。
  - **SSL-VPN 隧道**（atrust / EasyConnect 这类）：其 "SSL" 指**外层隧道**，把整条 TCP/IP 流**封装**进外层 SSL 后转发到校内网关，**内层 app TLS 仍端到端**、无人解密 → **兼容**（嵌套加密，非终止）。
  - **真正冲突的只有两类**，均默认禁止 / 须单独评估：① 我方 transport 在**客户端本地拆 TLS**（起本地代理、装根证书重签）→ 直接打穿红线 #1，**绝对禁止**；② 第三方网关被配成 **SSL-inspection（解密内层）模式** → 超出我方控制但意味着凭证在网关可见，须在 §2.4 探针识别。
  - 一句话：**封装式 VPN（含 SSL-VPN）不触本不变量；只有"本地终止/拦截 app TLS"才触。**
- **不持私密状态落公网**（红线 #2）：app-tunnel 的会话/握手状态只在客户端或校内授权环境，绝不经 `server/src/public`。
- **吊销 + kill-switch**：transport 二进制纳入 ADR-002 §2.4 吊销清单；可吊销某 transport 版本，核心据此降级到 `direct`/`system-vpn`（fail-safe）。

### 2.4 atrust VPN 复刻的接入 = 三件套探针先行（gate）

延续 ADR-000 §5.2"不焊死 + 开工前探针"，**未过探针不进实现**：

1. ~~**许可证探针**~~ **✅ 结论：自有 MIT**（Hermes；`LICENSE` 全文 + `Cargo.toml` 声明，2026-09-09 核实），依赖树零 GPL 系。
2. **协议模式探针**：协议稳定度（按年变更）、复刻完成度、能否在 user-space 网络栈实现（决定可移植性）；**并显式确认该客户端是"纯隧道封装"还是会"本地终止 / 拦截 app TLS"**（§2.3）——若属后者即触红线 #1，按 §3.4 走单独 ADR + 安全评审，默认不上。
3. ~~**iOS 可行性探针**~~ **✅ 结论：iOS 可上**。两道门都开了——MIT 消解分发不相容（§2.5），**形态 B** 不用 `NetworkExtension`、不需 entitlement、不触指南 5.4（§2.6）。原「预期结论：iOS 不上 app-tunnel」作废。

接入形态：作为 §2.1 抽象下的**一个 `app-tunnel` 实现**，坏了/上游停维即切回 `direct`/`system-vpn`，不焊死。

### 2.5 许可证：标的为 MIT，GPL 隔离方案已不适用（2026-09-09 修订）

**`app-tunnel` 的标的已定为 Hermes（自有 MIT，依赖树零 GPL 系）**，见
[`adr_032`](./adr_032_app_tunnel_embedding.md) §2.1 与 [`probe_002`](../probes/probe_002_atrust_tunnel.md)。
于是本节原先的两个问题**同时消失**：

- **链接传染**（GPL 代码链进主二进制）→ 不存在，可用进程内 FFI（ADR-032 §2.2），不必进程隔离。
- **商店分发不相容**（GPLv3 vs App Store DPLA）→ 不存在，**iOS 重新可行**。

叠加 §2.6 已为**形态 B** 解除 NetworkExtension / entitlement / 指南 5.4 的封锁，**iOS 的 `app-tunnel`
两道门都开了**（§2.2 矩阵与 [`adr_010`](./adr_010_ios_appstore.md) §2.3 已同步）。

**核实（2026-09-09）**：ADR-032 §2.1 的放行条件「Hermes 仓补 `LICENSE` 文件」**已满足**——
仓内已有 MIT 全文，`Cargo.toml` 亦声明 `license = "MIT"`（红线 #9 的许可证声明义务据此成立）。

> **原 GPLv3 分平台隔离矩阵与「三条根本出路」已归档**至
> [`docs/archive/adr_003_gpl_isolation_superseded.md`](../archive/adr_003_gpl_isolation_superseded.md)。
> **它没有变成错的，只是不再适用于当前标的**——若 Hermes 落空、回到 zju-connect（AGPLv3）或任何
> GPL 系实现，那份分析原样有效。

**仍未解除的**：ADR-032 整体仍为 **Proposed**；其 §2.6 要求的「表达性选择复现审查」须由**人工**完成
（AI 不得自评）。该审查未完成前，**不得合并任何隧道实现代码**。

### 2.6 `app-tunnel` 的两种形态：包级隧道 vs 应用层代理隧道（2026-07-24 讨论澄清，AI 起草待人工审）

§2.2/§2.3 早先谈 `app-tunnel` 时，默认想象的是**包级隧道**（建 TUN / 接管 OS 路由，iOS 上即 `NEPacketTunnelProvider`），把"隧道"与"占系统 VPN 槽 + 进内核"隐性绑死了。实际存在第二种形态，两者信任档相同（都仍是 `app-tunnel`：仅官方签名、最高信任、人工主导），但**平台可用性与 iOS 合规判定截然不同**：

| 子形态 | 机制 | 看到的流量 | 系统 VPN 槽 / 内核 | iOS |
|---|---|---|---|---|
| **A · 包级隧道** | 建 TUN 设备 / 接管 OS 路由；iOS = `NEPacketTunnelProvider`（独立扩展进程 + 内存上限） | **全 OS 流量** | 占用（系统唯一 VPN 槽）、需内核/扩展 | 触 NetworkExtension + entitlement + 指南 5.4；可 always-on 后台 |
| **B · 应用层代理隧道** | **用户态网络栈**（gVisor 类）在**普通进程内**跑，不建 TUN、不改 OS 路由 | **仅本进程经隧道的流量** | **不占用、不进内核** | **不用 NetworkExtension、不需 entitlement、不触 5.4**；不能 always-on 后台 |

**形态 B 的南北两向（关键澄清）**：

- **南向（面向 elecon 本体）= 标准协议**：用户态栈对上暴露**标准 SOCKS5 / HTTP CONNECT 代理**；elecon 的 HTTP 栈指过去即可。**elecon 自用甚至无需监听端口**——可让原生库直接暴露"经隧道 dial/fetch"函数，进程内调用，连 loopback 端口都省（监听端口仅在需给其他 app 当代理 / 需进程隔离 IPC 边界时才要）。
- **北向（面向学校网关）= 网卡上是标准 HTTPS、载荷是私有协议**：对网关只开**一条标准出站 TLS:443 连接**，私有 aTrust/EasyConnect 协议封装在该 TLS 载荷内。从 OS / 网卡 / iOS 看，就是个普通出站 HTTPS socket。参照实现 zju-connect 的**默认即形态 B**（gVisor 用户态栈 + `127.0.0.1:1080` SOCKS / `:1081` HTTP；其 TUN 模式才需 root）。

**红线不变量在形态 B 下依旧成立**：代理只见目标 `host:port`（SOCKS CONNECT 层），内层 elecon→origin 的 TLS 端到端嵌套在隧道内，凭证在内层密文中——正是 §2.3「封装非终止」，红线 #1 原样守住。区别仅在：形态 B 看到的是"elecon 自身经隧道的流量"，而非形态 A 的"全 OS 流量"。

**iOS 判定修订（同步 [ADR-010](./adr_010_ios_appstore.md) §2.3）**：§2.2 平台矩阵中 `app-tunnel` 一行"iOS 默认不编入"的封锁**仅适用于形态 A**。**形态 B 的 `app-tunnel` iOS 可上**——它不建 NetworkExtension，从 iOS 视角是普通出站 TLS app，不触 5.4 / entitlement / VPN 槽。唯一代价：普通 app 后台被挂起 → 无 always-on 隧道；但 elecon 的 on-demand 取数（开 app→连隧道→拉数据→拆）**不需要 always-on**，可接受。残余小风险：私有协议逆向连校网关的第三方服务合规（指南 5.2.2），备学校认可学生 VPN 使用的材料缓解。

**开放问题（显式未决，须子 ADR + 人工主导，AI 不得独自闭环 · 红线 #10/#4）**：

> **2026-08-06 移交**：以下三问已移交 [`adr_032_app_tunnel_embedding.md`](./adr_032_app_tunnel_embedding.md)（**提议中，尚未接受**），事实基础见 [`probe_002_atrust_tunnel.md`](../probes/probe_002_atrust_tunnel.md)（三件套探针，判定 go 附条件）。**在 ADR-032 被接受前，本节三问仍视为未决**，不得据此合并任何隧道实现。探针带出的一项关键事实：候选标的为**自有 MIT** 许可证，故本文 §2.5 的 GPL 隔离矩阵与 §2.2 平台矩阵中 `app-tunnel` 行的「触及 GPL/entitlement = 是」对该标的不成立。

1. **是否净室重写** aTrust/EasyConnect 北向协议（产出自有许可证代码 → 彻底消除 AGPL 传染），**还是**直接接入 AGPLv3 的 zju-connect（经进程隔离 + 回环，隔离链接传染但 iOS 仍被 DPLA 挡、见 ADR-010 §2.3）。
2. **若净室 / 自研，嵌入形态**：Rust FFI（进程内链接，自有许可证下无传染）**vs** 本地回环（独立进程 + 标准 SOCKS/HTTP，最强隔离）。注：形态 B + elecon 自用时可退化为"进程内直接 dial、无监听端口"（见上南向）。
3. **净室的 AI 特有风险**：净队模型的权重可能已训练过公开源码（zju-connect / EasierConnect 均公开），须以"产出可逐条追溯到人工审过的规格文档 + 人工审是否复现原码表达性选择"缓解——这不是传统人类净队的风险，须在探针 / 子 ADR 中显式管住。

---

## 3. 已知约束与风险（Consequences）

1. **承重 + 最高信任面（红线 #1）。** transport 看全部流量，实现与测试**不得 AI 独自闭环**；需安全检查清单 + 人工审阅（git.md §3：`transport`/签名属最严档）。
2. **许可证是法律面，非工程可独断**（ADR-010 §3.4）。当前标的 Hermes 为自有 MIT（§2.5），GPL 传染与商店分发不相容均不适用；**但净室重写本身的合规论据**（表达性选择未复现原码）仍须人工审查确认（ADR-032 §2.6），本文不构成法律意见。若日后改用 GPL 系实现，[归档的隔离矩阵](../archive/adr_003_gpl_isolation_superseded.md)重新适用。
3. **`system-vpn` 的可用性代价。** 依赖用户操作 + 系统/第三方 VPN 可用性，校外体验不如 app-tunnel 顺滑——已接受的代价（与 ADR-000 §5.2 校外天花板、ADR-010 §3.5 跨平台不对称一致）。
4. **"TLS 不终止"是硬不变量。** 若未来某 transport 需要看明文（如协议改写），即触碰红线 #1，**必须单独 ADR + 安全评审**，默认禁止。
5. **跨平台能力不对称**（iOS 最弱）带来产品文案/预期管理成本。**2026-09-09 收窄**：MIT 标的 + 形态 B 使 iOS 的 `app-tunnel` 可行（§2.5/§2.6），iOS 与 Android 的差距缩小到「无 always-on 后台隧道」一项；elecon 的 on-demand 取数不需要 always-on，故该项影响有限。Windows 仍受限（ADR-032 §4.7：UDS 不可用）。
6. **分流的风险由「每请求单通道」承接（2026-09-09 修订）。** 原文写「单 active transport；split-tunnel 不在本文」，
   与 §2.6 的形态 B 冲突——形态 B 天生分流。真正要防的不是「存在多条通道」，而是**某个请求走错通道**：
   按域名分流若判据模糊，就会出现「本应走隧道的私密流量误走直连」。§2.1 的**每请求单通道 + 禁止静默降级**
   即为此而设：判据不是域名模式匹配，而是 §2.1.1 声明的**可达性要求**（`public` / `campus`），
   由核心在发出前唯一裁定，不可达即 fail-closed。**残余风险**：可达性声明本身若写错（把 campus 端点标成 public），
   仍会导致误走直连——故该声明是**签发期可审的 manifest 字段**，纳入 validator 静态检查，而非运行时推断。
7. **待确认（接受前）：iOS Personal VPN entitlement 可得性。** `system-vpn` 档在 iOS 依赖 **Personal VPN entitlement**（`NEVPNManager`）。其门槛远低于 Network Extension，但仍是一项 entitlement 依赖，且 [ADR-010](./adr_010_ios_appstore.md) 未就此评估。**取向**：标注"待确认"即可接受本 ADR——若该 entitlement 因审核策略不可得，iOS 的 `system-vpn` 引导退化为"提示用户在系统设置自行配置 VPN"（纯引导、零 entitlement），不阻塞 `direct` 档与本 ADR 主体。须在 iOS 上架评估（§4 / ADR-010 §3.3）时一并确认。

---

## 4. 落地清单（拆成可审查的小 PR）

> 本 ADR 已接受（见头部状态）；`app-tunnel` 的实现另受 [`adr_032`](./adr_032_app_tunnel_embedding.md) 门控（仍为 Proposed，未接受前不得合并隧道代码）。落地与签收状态见 [`README.md`](./README.md)，本文不重复记录。

> 安全敏感项标（人工主导、AI 仅辅助）：

- **transport 抽象接口（核心侧）**：lifecycle/status/routing 窄接口；单 active + 运行时切换 + 降级链；**TLS 不终止**不变量落为代码约束。客户端与（如适用）`server/src/campus` 对齐。
- **门控与治理（2026-09-09 改写）**：~~transport 二进制验签~~ 已作废（§2.3：编译期编入，无加载门）。改为 **平台 / profile build flag**（决定哪些档编入哪个产物）+ **远程开关**（不发版禁用 / 启用某档，核心按 §2.2 降级链退档）+ **无侧载入口断言**（DEPLOY/DEV 均无 transport 动态加载路径）。
- **`direct` / `system-vpn` 两档先行**：`direct` = OS 网络；`system-vpn` 经 `NEVPNManager`(iOS)/`VpnService`(Android) 引导 + 可达性检测 + 降级。
- ~~**三件套探针（atrust）**~~ **✅ 已完成**：见 [`probe_002_atrust_tunnel.md`](../probes/probe_002_atrust_tunnel.md)，判定 **go（附条件）**；许可证 MIT、形态 B、纯封装不终止 app TLS（西电真机三目标 HTTP 200 且证书完整校验）。
- **许可证（若上 `app-tunnel`）**：标的 MIT，无隔离要求；须在依赖清单声明许可证（红线 #9）并保留 MIT 版权声明。净室合规的人工审查见 ADR-032 §2.6。
- **契约（如需，独立 ADR）**：数据信封（data envelope，ADR-001 §3.3）`source.origin` 增 transport 维度（如 `client-direct` 经 direct/tunnel），与 ADR-001/009 协调、向后兼容。
- **测试**：transport 状态机/降级链单测；**TLS-不终止**断言；签名/吊销正反例；不在 UI 线程阻塞（红线 #7 同源精神，原生侧勿阻塞主线程）。
