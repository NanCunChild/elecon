# Probe-002 · aTrust `app-tunnel` 三件套探针（许可证 / 协议模式 / iOS 可行性）

> **类型**：go/no-go 探针（gate）。落实 [V1 ADR-000](../adr/archived/v1/adr_000_abstract.md) §5.2 与 [V1 ADR-003](../adr/archived/v1/adr_003_transport.md) §2.4 明列的「三件套探针」：**未过探针不进实现**。
> **状态**：📋 起草（①②已有实测证据待人工确认；③ 本轮不适用，结论待补）。**本文档结论须人工签收后**，才可进入 ADR-032 与任何隧道实现 PR。
> **标的**：`/home/nancunchild/projects/Hermes`（aTrust SSL-VPN 的 Rust 净室重写，`origin = github.com/ncc-devlab/Hermes-Atrust`）。
> **关联**：V1 ADR-003 §2.4（探针定义）/ §2.5（许可证隔离）/ §2.6（形态 A vs B + 三个开放问题）· [V1 ADR-010](../adr/archived/v1/adr_010_ios_appstore.md) §2.3 · V1 ADR-032。
> **🔒 合规**：transport 是看**全部流量**的最高信任面（红线 #1/#4）。按 [AGENTS.md](../../AGENTS.md) §1，本文由 AI 起草，**结论与后续实现不得 AI 独自闭环**，须人工主导 + 安全检查清单 + 人工审。本文不含任何真实凭证 / cookie / SID / SignKey 值（红线 #8）。

---

## 0. 为什么现在做这个探针

ADR-003 已接受，但 `app-tunnel` 档**实现为零**，且 §2.6 末尾留了三个显式未决的开放问题（净室与否 / 嵌入形态 / 净队 AI 风险），要求「子 ADR + 人工主导」。同时 §2.4 规定三件套探针是硬 gate。

触发本次探针的事实变化：Hermes 的数据面在 2026-07-31 ~ 2026-08-06 期间从「未实现」推进到**在西电真实网关上跑通端到端 HTTPS**。这使 ADR-003 §2.4 第 2 项（协议模式探针）第一次具备了可判定的实测依据——尤其是其中最关键的一问：**该客户端是"纯隧道封装"还是会"本地终止 / 拦截 app TLS"**。

---

## 1. 探针 ① · 许可证

**ADR-003 §2.4 要求**：确认复刻的确切 license（GPLv3？有无链接例外？）、作者是否愿独立/双授权。

### 1.1 标的自身

| 项 | 结果 | 证据 |
|---|---|---|
| 声明许可证 | **MIT** | `Hermes/Cargo.toml` `[workspace.package] license = "MIT"` |
| LICENSE 文件 | **❌ 缺失** | 仓库根无 `LICENSE`；`git log --diff-filter=A` 确认从未提交过 |
| 作者归属 | 本项目作者自有（非第三方 fork：单一 remote，无 upstream） | `git remote -v` |

**→ 与 ADR-003 §2.5 的关系**：§2.5 整张「GPL 分平台矩阵」与「三条根本出路」是为 **GPLv3/AGPLv3 标的**写的（zju-connect 是 AGPLv3）。标的为自有 MIT 时：**链接传染不成立、商店分发不相容不成立**——§2.5 的进程隔离要求整块不适用，ADR-003 §2.6 开放问题 1（净室 vs 接入）自动落在「净室」一侧。

**→ 阻塞项**：必须补 `LICENSE` 文件。红线 #9（新依赖须声明许可证）要求的是可验证的声明，`Cargo.toml` 一行 `license = "MIT"` 不构成分发许可。

### 1.2 依赖树普查

对 `Hermes/Cargo.lock` 全部 **236** 个 package 逐个从本机 cargo registry 缓存读 `license` 字段：

| 许可证 | 包数 |
|---|---:|
| MIT OR Apache-2.0 | 105 |
| MIT | 34 |
| Unicode-3.0 | 18 |
| Apache-2.0 OR MIT | 16 |
| MIT/Apache-2.0 | 5 |
| Unlicense OR MIT · Apache-2.0 OR ISC OR MIT · MIT OR Apache-2.0 OR Zlib · ISC | 各 2 |
| Apache-2.0 AND ISC（`ring`）· Apache-2.0 OR BSL-1.0 · BSD-3-Clause · Apache-2.0 · Zlib OR Apache-2.0 OR MIT · (MIT OR Apache-2.0) AND Unicode-3.0 · **CDLA-Permissive-2.0**（`webpki-roots`）· BSD-2-Clause OR Apache-2.0 OR MIT | 各 1 |
| **合计已解析** | **194** |

**GPL / LGPL / AGPL 命中数：0。**

未解析 42 项 = 11 个 Hermes 自有 workspace crate（继承 MIT）+ 31 个**本机 registry 未缓存**的包。后者全部是 `wasm-bindgen` / `web-sys` / `js-sys` / `windows-*` / `wasi` / `r-efi` 系——即 **wasm 与 Windows 目标的传递依赖，在 Linux 上不参与构建**，也不会进 Android 产物。

**→ 待办（不阻塞结论，但须补齐证据）**：在 CI 用 `cargo deny check licenses` 对**实际构建目标**（`aarch64-linux-android`）出完整报告，把这 31 项闭合。同时注意：上表是**整个 workspace**（含 `atrust-browser`/`atrust-probe`）的依赖树；`hermes-ffi` 的实际依赖树更小，最终报告应针对它出。

### 1.3 探针 ① 判定

**✅ pass（待人工确认）** —— 标的自有宽松许可，依赖树零 GPL 系。**放行条件**：补 `LICENSE` 文件 + 出针对 Android 构建目标的 `cargo deny` 报告。

---

## 2. 探针 ② · 协议模式

**ADR-003 §2.4 要求**：协议稳定度、复刻完成度、能否在 user-space 网络栈实现；**并显式确认是"纯隧道封装"还是会"本地终止 / 拦截 app TLS"**（后者触红线 #1，默认不上）。

### 2.1 「纯隧道封装 vs 本地终止 TLS」——本探针最关键的一问

**结论：纯隧道封装。elecon→origin 的 TLS 端到端，隧道模块只见密文。**

判定依据不是代码审阅的印象，而是 Hermes 在西电真实网关上的实测（`Hermes/docs/open-questions.md` §D4，2026-08-05）：经 aTrust TCP 隧道对三个目标各完成一次完整的目标 TLS 握手 + HTTP 请求，**目标证书完整校验通过**：

| 目标 | HTTP | body | 目标证书校验 |
|---|---:|---:|---|
| `gsoft.xidian.edu.cn:443` | 200 | 67361 B | `certificate_verified=true` |
| `www.xidian.edu.cn:443` | 200 | 164887 B | 同上 |
| `www.cnki.net:443` | 200 | 106360 B | 同上 |

**为什么这构成"不终止 TLS"的直接证据**：目标证书由客户端自己的 TLS 栈按目标域名校验并通过，说明链路上没有任何一方重签或替换证书。若隧道在本地拆 TLS，客户端看到的必然是隧道自签的证书，校验必然失败（或必须关闭校验才能通过）——这正是 ADR-003 §2.3 所禁止的两类情形之一。

同时对应 ADR-003 §2.3 的分类：aTrust 属该节明列的 **「SSL-VPN 隧道 → 嵌套加密，非终止 → 兼容」**。其 "SSL" 是外层隧道，内层 app TLS 原样穿过。

**残余项（须在 ADR-032 定案，不阻塞本探针）**：ADR-003 §2.3 提到的第二类冲突「第三方网关被配成 SSL-inspection 模式」——本探针未能直接排除。但上表的 `certificate_verified=true` 是**针对目标站点真实证书**的校验通过，若网关在做 SSL-inspection，该校验会失败。因此实测同时否证了这一项。

### 2.2 能否在 user-space 网络栈实现（→ 形态 A/B 判定）

**能，且现状即形态 B。** Hermes 全 workspace 对 `tun` / `tun-rs` / `wintun` / `/dev/net/tun` 零依赖零命中，三处 crate 级文档明写 TUN 不在范围内（`atrust-l3`：「TUN, DNS and routing are deliberately out of scope」；`atrust-client`：「Still no TUN, no DNS, no routes and no login」）。

对照 ADR-003 §2.6 的两个子形态：

| §2.6 判据 | Hermes 现状 |
|---|---|
| 不建 TUN 设备 / 不改 OS 路由 | ✅ 无 TUN 代码 |
| 不占系统唯一 VPN 槽、不进内核 | ✅ 普通进程内用户态 |
| 北向对网关一条标准出站 TLS:443 | ✅ `hermes-transport::connect_tls` → 节点 TLS，私有协议封在载荷内 |
| 南向暴露标准协议 / 可退化为进程内直接 dial | ✅ `AtrustClient::dial_tcp` 返回实现 `AsyncRead + AsyncWrite` 的 `TcpTunnel`——即"进程内直接 dial、无监听端口"形态 |

**→ 判定为 ADR-003 §2.6 形态 B。** 据 §2.6 的 iOS 判定修订，形态 B 不触 NetworkExtension / entitlement / 指南 5.4。

### 2.3 复刻完成度与协议稳定度

| 项 | 状态 |
|---|---|
| 控制面（authConfig / CAS+MFA 登录 / 会话 / clientResource / 节点解析 / 资源匹配） | ✅ 西电实测通过 |
| TCP 隧道数据面（DialTCP 握手 + 应用帧 + 关闭） | ✅ 西电实测通过（§2.1 三个目标） |
| L3 数据面（Get-IP / 五元组鉴权 / 全双工 / conntrack / 重连） | ✅ 西电实测通过（2026-08-03/04） |
| TUN / DNS / 路由 / SOCKS / 端口转发 | ❌ 明示不在范围（本次也不需要——elecon 走 TCP 档） |
| Windows | ❌ 无法编译（`std::os::unix` 无条件使用）。**不影响 Android**（Android 是 Unix） |

协议关卡由 `Hermes/docs/open-questions.md` 以 L0–L3 证据强度分级登记，关键项（A1 `0x94` 双格式判据、A2 VIP 长度、B1 SignKey、D2 节点 SNI、D4 端到端）均已取得 **L0（西电官方网关实测）** 样本。该文档明确把 L2（重建的推测服务端）标注为「不是证据」——这个纪律本身可以采信。

### 2.4 探针 ② 判定

**✅ pass（待人工确认）** —— 纯隧道封装、不终止 app TLS、可在用户态实现、属形态 B、TCP 档完成度足以支撑 elecon 的取数需求。

**→ 但 pass 附带两条必须在 ADR-032 解决的前置条件**（见 §4）。

---

## 3. 探针 ③ · iOS 可行性

**ADR-003 §2.4 要求**：`NetworkExtension` entitlement 可得性 + GPLv3 分发（ADR-010 已判不相容）→ 预期结论「iOS 不上 app-tunnel」。

**本轮判定：不适用（本轮不上 iOS），但 §2.4 的两个前提均已改变，须回写 ADR-010。**

| §2.4 原假设 | 现状 |
|---|---|
| 需要 `NetworkExtension` entitlement | **不需要** —— 形态 B（§2.2 已判定）不建 NetworkExtension，从 iOS 视角是普通出站 TLS app（ADR-003 §2.6 iOS 判定修订 / ADR-010 §2.3 修订） |
| GPLv3 与 App Store DPLA 不相容 | **不适用** —— 标的自有 MIT（§1.1） |

**→ 即 ADR-010 §2.3「iOS 二进制内不含 GPLv3 传输底座」这条封锁，对本标的不成立。** ADR-010 §4 的复评触发器（「当 App 内传输底座拟上 iOS 时，回到本文重做 §2.1 三段论自检」）已被触发。

**残余风险（未评估，本轮不阻塞）**：App Store 指南 **5.2.2**——逆向私有协议连接第三方（学校）网关的合规性。ADR-003 §2.6 给的缓解是「备学校认可学生 VPN 使用的材料」。**本轮不上 iOS，此项留待 iOS 上架评估时执行。**

### 3.1 探针 ③ 判定

**⬜ 本轮 N/A** —— 首发 Android，iOS 不编入（build flag 门控）。原「iOS 因 GPL + entitlement 不可上」的结论**已失效**，但「可上」需要另做 5.2.2 评估才能主张，本探针不予认定。

---

## 4. 探针放行的前置条件（新发现，非 §2.4 原列，但必须解决）

三件套本身 ①② pass、③ N/A，但探针过程中发现三项 ADR-003 未预见的问题。**它们不推翻探针结论，但必须在 ADR-032 定案、并在实现中落地**：

| # | 问题 | 为什么必须处理 |
|---|---|---|
| **P-1** | **外层节点 TLS 目前必须关闭校验**。数据面节点证书是自签 `CN=sdp`，默认 `Verify` 策略必然失败，实测全程用 `--insecure-tls`。`hermes-transport::TlsPolicy` 目前只有 `Verify` / `DangerousAcceptInvalidCertificates` 两态。 | 内层目标 TLS 完整校验（§2.1）保住了红线 #1，但**外层隧道对主动中间人无防护**是一个独立的暴露面。须改为对节点证书做 pinning/SPKI 校验，而不是关校验。 |
| **P-2** | **会话材料是一类新凭证**。`SessionMaterial { sid, device_id, connection_id, sign_key, username }` + 网关 cookie jar：SignKey 每帧签名都要用，隧道模块在会话期必然持有。 | 红线 #1 现有条文管的是「注入到 origin 请求里的凭证」，不覆盖隧道自身的会话密钥。须明确托管边界（核心持有 / 按需下传 / disconnect 即 zeroize / 永不落日志）。 |
| **P-3** | **Hermes 的会话持久化把凭证明文落盘**。`crates/atrust-auth/src/store.rs` 的 `StoredSession` 以明文 JSON（`0600`，无加密）写 cookie 值 / SID / SignKey hex；另有刻意不脱敏的 `--browser-trace-file`。 | 对桌面诊断是合理设计，对移动端不是。持久化必须由 elecon 既有凭证存储（含硬件 keystore）承担；`hermes-ffi` 不得暴露任何 session-file 路径参数。 |

---

## 5. 结论

| 探针 | 判定 | 放行条件 |
|---|---|---|
| ① 许可证 | ✅ pass | 补 `LICENSE` 文件；出 Android 目标的 `cargo deny check licenses` 报告 |
| ② 协议模式 | ✅ pass | P-1 / P-2 / P-3 在 ADR-032 定案 |
| ③ iOS 可行性 | ⬜ N/A（本轮不上） | 若日后上 iOS：单独做指南 5.2.2 评估，回写 ADR-010 |

**→ go（附条件）**：可进入 ADR-032 起草。**ADR-032 被接受前，不得合并任何隧道实现代码。**

### 须回写的文档

- **ADR-003 §2.6 开放问题**：1（净室 vs 接入）→ 净室，本探针 §1.1 定案；2（嵌入形态）与 3（净队 AI 风险）→ 移交 ADR-032。
- **ADR-010 §2.3**：「iOS 二进制内不含 GPLv3 传输底座」对本标的不适用；§4 复评触发器已触发。
- **ADR-003 §2.2 平台矩阵**：`app-tunnel` 行的「触及 GPL/entitlement = 是」对本标的应为「否」。

### 未由本探针认定的事项（避免被误读为已放行）

- 未认定 iOS 可上架。
- 未认定 L3/TUN 档可用（本轮只认定 TCP 档）。
- 未认定 elecon 侧接法可行——Dart 在隧道 socket 上完成 TLS 的具体机制属实现验证，见 ADR-032 与实施计划 P2。
- 未对 Hermes 代码做安全审计。净室产出的 AI 特有风险（ADR-003 §2.6 开放问题 3）**未由本探针缓解**，须在 ADR-032 单列。
