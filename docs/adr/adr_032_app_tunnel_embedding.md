# ADR-032：`app-tunnel` 的嵌入形态与会话材料托管（承接 ADR-003 §2.6 开放问题）

- **状态**：📋 提议（Proposed，AI 起草）。**未接受前不得合并任何隧道实现代码。** transport 是看**全部流量**的最高信任面，按 [AGENTS.md](../../AGENTS.md) §1 与 [ADR-003](./adr_003_transport.md) §3.1，**AI 不得独自闭环**：本文须人工主导评审 + 安全检查清单 + 人工审签。
- **日期**：2026-08-06
- **适用范围**：`app-tunnel` 传输档的**嵌入形态、数据面接法、会话材料托管边界、外层隧道 TLS 策略、信任与平台门控**。**不含** adapter 信任分档（ADR-002）、凭证注入/脱敏机制（ADR-009/029）、UI。
- **触及红线**：#1（凭证永不离开核心）、#4（传输底座仅官方签名加载）、#9（新依赖须声明许可证）、#10（架构性改动先写 ADR）
- **依赖**：[`ADR-003`](./adr_003_transport.md)（母 ADR：§2.1 窄接口 / §2.2 三档与降级链 / §2.3 安全不变量 / §2.6 形态 A vs B 及三个开放问题）、[`ADR-002`](./adr_002_trust_model.md)（签名/吊销/kill-switch）、[`ADR-010`](./adr_010_ios_appstore.md)（iOS 分发）、[`ADR-012`](./adr_012_credential_store.md)（凭证存储）、[`Probe-002`](../probes/probe_002_atrust_tunnel.md)（三件套探针，本 ADR 的事实基础）

---

## 1. 背景

ADR-003 已接受，定义了 transport 的窄接口、三档传输、降级链与安全不变量，并在 2026-07-24 的 §2.6 修订里区分了「包级隧道（形态 A）」与「应用层代理隧道（形态 B）」。但它在末尾留了**三个显式未决的开放问题**，并要求「子 ADR + 人工主导」：

1. 是否净室重写 aTrust 北向协议，还是接入 AGPLv3 的 zju-connect；
2. 若净室/自研，嵌入形态是 Rust FFI（进程内）还是本地回环（独立进程）；
3. 净室的 AI 特有风险（模型权重可能已训练过公开源码）。

本文承接这三问，并补上探针过程中暴露的、ADR-003 未预见的三项（[Probe-002](../probes/probe_002_atrust_tunnel.md) §4 的 P-1/P-2/P-3）。

事实基础见 Probe-002：标的 Hermes 自有 MIT、依赖树零 GPL 系、属形态 B、**纯隧道封装不终止 app TLS**（西电真机三个目标 HTTP 200 且目标证书完整校验）。探针判定 **go（附条件）**。

---

## 2. 决策

### 2.1 净室重写（ADR-003 §2.6 开放问题 1）

**采净室自研（Hermes），不接入 zju-connect。**

理由不是工程偏好，而是许可证：标的自有 **MIT** → ADR-003 §2.5 整张「GPL 分平台矩阵」与「三条根本出路」不适用，链接传染与商店分发不相容两个问题同时消失。这也是 §2.5 明列的出路 2「clean-room 以相容许可证重写——**唯一**能让 in-app tunnel 上 iOS 的路径」。

zju-connect 的角色**限定为逐行对照的参考实现**（Hermes 文档中的 L1 级证据），不作为依赖、不引入其 AGPLv3。

**放行条件**：Hermes 仓补 `LICENSE` 文件（当前仅 `Cargo.toml` 一行声明，不构成分发许可，红线 #9）。

### 2.2 嵌入形态（ADR-003 §2.6 开放问题 2）

**进程内 Rust FFI 承载控制面 + per-dial Unix domain socket 承载数据面。**

ADR-003 §2.6 把选项列为「Rust FFI（进程内）**vs** 本地回环（独立进程）」，并注明形态 B 自用时可退化为「进程内直接 dial、无监听端口」。本文采**两者的组合**，理由是一个 ADR-003 起草时未知的技术约束：

> **`dart:io` 无法在任意字节流上做 TLS。** `SecureSocket.secure()` 只接受真实 `Socket`，不存在 `secureFromStream`。

因此「裸字节 FFI 管道（`conn_read`/`conn_write`）+ Dart 在其上做 TLS」这条最直觉的路径**不可实现**。三个候选的取舍：

| 方案 | TLS 在哪 | 红线 #1 | 网络可见面 | 判定 |
|---|---|---|---|---|
| 裸字节 FFI 管道 | Dart（期望） | ✅ | 无 | ❌ **技术不可行**（无 `secureFromStream`） |
| **per-dial UDS** | **Dart** | ✅ | **无监听端口**，UDS 落 app 私有目录由沙箱文件权限隔离 | ✅ **采用** |
| loopback SOCKS/HTTP CONNECT | Dart | ✅ | `127.0.0.1:port`，Android 上**同设备任何 app 可连** | ⚠️ 兜底 |
| 请求级 FFI（`fetch(request)`） | Rust | ❌ **打穿红线 #1** | — | ❌ **绝对禁止** |

采用形态：

```
Dart  connectionFactory(uri, _, _) async {
        final path = await hermes.prepareDial(uri.host, port);  // FFI，一次性 UDS 路径
        return Socket.startConnect(InternetAddress(path, type: unix), 0);
      }
      // HttpClient 随后对 https 目标在该 socket 上完成 TLS —— host 取自目标 URI
Rust  prepare_dial() → app 私有目录建一次性 UDS listener；accept 后 unlink；
      把该连接与 AtrustClient::dial_tcp(host, port) 得到的 TcpTunnel 双向 copy
```

**FFI 只承载控制面**（`tunnel_start` / `tunnel_status` / `tunnel_stats` / `tunnel_events` / `prepare_dial` / `tunnel_stop`），不逐包过桥。这同时压掉了 Dart↔Rust 编组开销与 unsafe 胶水面。

**兜底**：若 `HttpClient.connectionFactory` 对 https 的自动 TLS 升级行为经实测不成立，退到 loopback HTTP CONNECT + 强制 `Proxy-Authorization`（每进程随机密钥）。**该退化须记为残余风险并回写本文**，不得默认启用。

### 2.3 红线 #1 的守护点：seam 必须落在 TLS 之下

**这是本 ADR 最重要的一条，评审须逐条盯死。**

ADR-009 的 broker 在 **TLS 之上的 HTTP 语义层**注入凭证；TLS 由 Dart 侧完成；**只有密文字节**进入隧道。隧道模块可见的仅有：目标 `host:port`、时序、体量。

由此推出三条禁令：

1. **禁止请求级 FFI**。不得把 `TransportRequest`（含已注入凭证的 headers/body）整体交给 Rust 侧发送——那等于把凭证明文交给一个独立信任模块，**直接打穿红线 #1**。
2. **禁止在隧道模块内做 TLS 终止 / 根证书注入 / MITM**（ADR-003 §2.3 原文即此）。
3. **禁止关闭内层目标 TLS 的证书校验**。Probe-002 §2.1 已实测内层可完整校验（`certificate_verified=true`），无任何理由放宽。

**可验证性**：这条不能只写在文档里。落地时须有自动化回归——在 UDS bridge 上抓字节，断言看不到任何注入凭证的明文（应全是 TLS record）。见 §6。

### 2.4 外层节点 TLS：pinning，不是关校验（Probe-002 P-1）

数据面节点证书是自签 `CN=sdp`，默认 `Verify` 必然失败，现有实测全程依赖 `--insecure-tls`。

**决策**：`hermes-transport::TlsPolicy` 增第三态 **`PinnedSpki`**（对节点证书公钥做 SPKI 指纹校验）。**release 构建禁用 `DangerousAcceptInvalidCertificates`**——该态仅在 dev/debug 构建保留用于协议诊断。

澄清分层，避免与 ADR-003 §2.3 混淆：

- **内层**（elecon → origin）：完整证书校验，**红线 #1 的凭证保护依赖这一层**，已实测通过。
- **外层**（elecon → aTrust 节点）：隧道自身的传输安全。关校验**不触红线 #1**（凭证仍在内层密文里），但它是一个**独立的主动中间人面**——攻击者若能中间人外层，可观测目标 `host:port` 元数据、注入/篡改隧道控制帧。因此不接受"反正内层是安全的"这一理由。

pin 值的来源与轮换（节点证书更换时的失效处理）须在实现 PR 中给出方案；**pin 失配一律 fail-closed**，降级走 ADR-003 §2.2 降级链，绝不静默放宽。

### 2.5 会话材料托管边界（Probe-002 P-2 · 红线 #1 的扩展）

隧道自身的会话凭证是一类**红线 #1 现有条文未覆盖**的新凭证：

| 材料 | 用途 | 谁必须持有 |
|---|---|---|
| `sid` / `device_id` / `connection_id` | 隧道会话标识 | 隧道模块（每帧使用） |
| `sign_key` | **每帧 HMAC 签名** | 隧道模块（会话期常驻） |
| 网关 cookie jar | `clientResource` 周期刷新（默认 300s）所需 | 隧道模块（经 `import_gateway_cookies`） |

**决策**：

1. **核心是唯一权威持有者**。材料由 elecon 核心在 WebView 登录收割后生成/组装，持久化走既有凭证存储（`client/lib/core/credential/`，含硬件 keystore），**按需下传**给隧道模块。
2. **隧道模块不得自行持久化**。`hermes-ffi` **不暴露任何 session-file 路径参数**；Hermes 的 `StoredSession`（明文 JSON 落盘 cookie/SID/SignKey）与不脱敏的 `--browser-trace-file` **不编入移动端产物**（Probe-002 P-3）。
3. **disconnect 即擦除**。`tunnel_dispose` 映射到 `AtrustClient::shutdown()`，并须拆掉在途 UDS bridge 与 `TcpTunnel`。Hermes 侧 `SecretString`/`SignKey` 已 `Drop` 时 `zeroize`，`Debug` 已全面脱敏——本条是对 FFI 边界的额外要求，不是重复。
4. **永不落日志**。事件流按 `hermes-events` 既有契约（「Events carry no credentials」，只报 `connect_token_len`）；elecon 侧 `DevLog` 同样不得记录材料值。
5. **adapter / UI 永不可见**。材料不进 QuickJS 沙箱、不进 SDUI 载荷。

**后续方向（不进首版，记录以免遗忘）**：`AuthClient::new(endpoint, transport: Arc<dyn HttpTransport>)` 的 transport 是 trait object，控制面 HTTP 完全可替换。把它接到 elecon 自己的 broker，可使网关 cookie 始终留在 elecon 核心、隧道模块只拿 `SessionMaterial`——对红线 #1 更干净。工作量大，留待评估。

### 2.6 净室的 AI 特有风险（ADR-003 §2.6 开放问题 3）

ADR-003 提出的风险：净队模型的权重可能已训练过公开源码（zju-connect / EasierConnect 均公开），须以「产出可逐条追溯到人工审过的规格 + 人工审是否复现原码表达性选择」缓解。

**本文不宣称该风险已缓解。** 可以记录的现状是：Hermes 以 `docs/atrust-protocol-analysis.md`（协议逆向）+ `docs/open-questions.md`（L0–L3 证据分级）+ `docs/server-behaviour-inferences.md` 形成了规格先行的书面链条，且明确把 zju-connect 标为 L1 参考、把重建服务端标为 L2「不是证据」。

**要求**：接受本 ADR 前，须由人工完成一次**表达性选择复现审查**——抽查 Hermes 与 zju-connect 在同一协议点上的实现，确认相似性来自协议约束而非代码表达的复制。该审查结论回写本节。**AI 不得自评此项。**

### 2.7 Transport seam 扩容（红线 #10：核心改动）

ADR-003 §2.1 要求 transport 有 `init/connect/disconnect/dispose` 生命周期与 `disconnected/connecting/connected/failed` 状态，但现有 seam 只有 `fetch()`（因为唯一实现 `direct` 的生命周期平凡）。

**决策**：扩 `Transport` 接口加生命周期与状态流；`DirectTransport` 的实现保持平凡（恒 connected）。同时引入单 active transport 选择器，落地 ADR-003 §2.2 降级链。

**范围限定**：只改**客户端** `client/lib/core/broker/fetch_proxy.dart`。服务端 `server/src/runtime/broker/fetch-proxy.ts` 的同名接口**不动**——隧道是纯客户端能力，不进公网哑服务（红线 #2）。这是本 ADR 有意接受的双端不对称。

### 2.8 平台门控与信任

| 平台 | 本轮 | 依据 |
|---|---|---|
| **Android** | ✅ 编入（首发） | 形态 B，无 entitlement 需求 |
| **iOS** | ❌ 不编入 | 非因 GPL（已不适用），而是指南 5.2.2 未评估（Probe-002 §3） |
| **OHOS / 桌面** | ❌ 不编入 | 优先级，非阻塞 |

**信任（红线 #4）**：`app-tunnel` 是最高信任档，**仅官方签名加载、release 无侧载入口**。原生 `.so` 的完整性由「编入官方包 + APK 签名」承担——**这与 ADR-002 现有的 adapter bundle 验签体系不是同一条链路**，本文明确记录该边界：ADR-002 §2.3/§2.4 的 Ed25519 bundle 验签**不覆盖**原生库。补偿手段是 **kill-switch**：隧道档纳入 ADR-002 §2.4 吊销清单，可远端禁用某版本，核心据此降级到 `direct`/`system-vpn`（fail-safe）。

---

## 3. 范围与非目标

**范围**：TCP 隧道档（`dial_tcp`）经 UDS 接入 elecon 的 `Transport` seam；控制面 FFI；会话材料托管；外层 TLS 策略；Android 门控。

**非目标（明确不在本文，需要时另立 ADR）**：

- **L3 / TUN 档**。`send_ipv4`/`recv_ipv4` 能力存在但本轮不接——它需要 TUN 或系统 VPN 槽，属 ADR-003 §2.6 形态 A，触 iOS NetworkExtension。
- **split-tunnel（按域名分流）**。ADR-003 §3.6 已判「放大私密流量裸奔风险，留待单独评估」。
- **always-on 隧道**。形态 B 后台被挂起；elecon 的 on-demand 取数模型不需要。
- **campus relay**。`server/src/campus` 的 501 blocker 写的是「等 ADR-003 定案」，而 ADR-003 早已接受——该 blocker 已过时，但 relay 的凭证落点属独立议题（见整改清单 P3-16），本文不代为决策。
- **envelope `source.origin` 增 transport 维度**。ADR-003 §4 提到，属契约改动，需要时单独小 ADR。

---

## 4. 已知约束与风险

1. **最高信任的原生面，无沙箱**。与 QuickJS 沙箱化的 adapter 不同，进程内 FFI 让 Rust 代码跑在 elecon 地址空间、有完整内存访问。Hermes 依赖树（236 包）并入 elecon 供应链（红线 #9）。
2. **unsafe 胶水**。Hermes workspace 是 `unsafe_code = "forbid"`；FFI crate 必须局部放开。**unsafe 只许存在于 `hermes-ffi` 一个 crate**，纳入审查。
3. **隧道可见元数据**。虽是密文，隧道仍看到 elecon 全部经隧道流量的目标 `host:port`、时序、体量——这是隐私面，日志纪律照红线 #1。
4. **双重加密开销**。内层 origin TLS + 外层隧道 TLS 嵌套，CPU/延迟叠加，移动端更敏感。
5. **首包延迟**。开 app → 建隧道（TLS 握手 + 签名 init 帧往返）→ 首次取数，链路显著长于 `direct`，需 UI 预期管理。
6. **降级链必须让用户看懂**。ADR-003 §2.2 是 fail-safe 非 fail-open：`app-tunnel → system-vpn 引导 → 只读公开缓存`，**任何分支绝不静默改成明文直连**。UI 须显式告知，由用户决策。
7. **UDS 的平台前提**。Unix domain socket 在 Linux/Android/macOS 可用，**Windows 不可用**；Hermes 本身也因无条件使用 `std::os::unix` 而无法在 Windows 编译。本轮不涉及，但限定了未来桌面 Windows 的路径。
8. **pin 轮换是运维负担**。节点证书更换会导致 pin 失配 → fail-closed 断网。须有更新通道，否则会变成"必须发版才能上网"。

---

## 5. 未决事项（接受前须由人工填写）

| # | 事项 | 状态 |
|---|---|---|
| U-1 | §2.6 的表达性选择复现审查（AI 不得自评） | ⬜ 待人工 |
| U-2 | `LICENSE` 文件补齐 + Android 目标 `cargo deny check licenses` 报告 | ⬜ 待执行 |
| U-3 | SPKI pin 值来源与轮换方案 | ⬜ 待定 |
| U-4 | `HttpClient.connectionFactory` 对 https 的 TLS 升级行为实测（决定是否走 §2.2 兜底） | ⬜ 待 spike |
| U-5 | 安全检查清单 + 人工审签 | ⬜ 待人工 |

---

## 6. 测试要求

安全敏感路径，测试与实现**同样不得 AI 独自闭环**。

| 断言 | 形式 |
|---|---|
| **红线 #1 回归**：UDS bridge 上抓字节，看不到任何注入凭证明文（应全是 TLS record） | 自动化，必须进 CI |
| **内层证书校验**：经隧道取数时 `X509Certificate` 校验通过且 CN 为目标域名而非 `sdp` | 自动化 |
| **无凭证落盘**：app 私有目录不产生任何含材料的文件 | 自动化 |
| **降级链不 fail-open**：隧道 `failed` → system-vpn 引导 → 只读缓存；**反例断言绝不回落明文直连** | 单测 |
| **pin 失配 fail-closed** | 单测（正反例） |
| **材料不可见**：adapter / UI 侧拿不到 `SessionMaterial` | 单测 |
| **kill-switch**：吊销后降级到 `direct`/`system-vpn` | 正反例 |
| Hermes 侧协议 | 沿用 `Hermes/docs/tunnel-plan.md` 门禁：mock 对端跑状态机单测；**真实拨号只 `#[ignore]` live，永不进默认 CI** |

---

## 7. 须回写的既有文档（接受后）

- **ADR-003 §2.6** 三个开放问题 → 指向本文。
- **ADR-003 §2.2** 平台矩阵：`app-tunnel` 行「触及 GPL/entitlement = 是」对本标的应为「否」。
- **ADR-010 §2.3**：「iOS 二进制内不含 GPLv3 传输底座」对本标的不适用；§4 复评触发器已触发。
- **ADR-000 §3.4**：transport 形态写的是「原生模块（Go/C + 用户态网络栈）」，实际为 Rust。
- **ADR-000 ADR 索引**：增补 `adr_032`。
