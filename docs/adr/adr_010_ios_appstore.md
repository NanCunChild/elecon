# ADR-010：iOS / App Store 分发合规（2.5.2 / DPLA 3.3.2）

- **状态**：已接受（Accepted）。**本文是分发策略与合规立场的结论**（回应 [#4](https://github.com/NanCunChild/elecon/issues/4) 的交付："给出可上架的形态或必要的架构调整"）。其中依赖 ADR-002（签名/侧载闸门，草案）、ADR-009（imperative requestGraph，草案）的条款，随这两份 ADR 的接受状态生效；涉及法律/授权的判断（VPN entitlement、GPL）须经 Apple 开发者支持 / 法务确认——**本文是工程合规判断，不是法律意见**。
- **日期**：2026-06-12
- **依赖**：[`adr_000_abstract.md`](./adr_000_abstract.md)（§2.3 固定能力契约、§3.3 凭证边界、§5.1 放弃图灵完备 UI DSL、§5.2 传输底座/许可证风险）、[`adr_008_client_runtime.md`](./adr_008_client_runtime.md)（§3 风险4：iOS 执行下载代码）、[`adr_009_fetch_credential.md`](./adr_009_fetch_credential.md)（imperative requestGraph 联动）、[`adr_002_trust_model.md`](./adr_002_trust_model.md)（签名/侧载闸门——支撑"非代码市场"论点；草案）
- **相关 issue**：[#4](https://github.com/NanCunChild/elecon/issues/4)（本文为其结论）
- **适用范围**：elecon 客户端在 **iOS / App Store** 上的可上架形态。覆盖三件相互纠缠的事：① 用 QuickJS 执行**下载来的** adapter JS（指南 2.5.2）；② App 内隧道 / VPN 传输底座（指南 5.4）；③ atrust 复刻的 GPLv3 与商店分发的相容性。Android / HarmonyOS 不在本文（其商店规则另评）。

---

## 1. 背景（Context）

ADR-008 §3 风险4 把"iOS 上用 QuickJS（`flutter_qjs`）执行下载来的 adapter JS"列为开放项：触及 **App Store 审核指南 2.5.2**——

> App 应自包含于其 bundle，**不得下载、安装或执行会引入或改变 App（含其他 App）功能的代码**。教育类 App（教学/测试可执行代码）在有限情形下可下载代码，但须让源码对用户完全可见可编辑。

字面看，"下载 adapter JS 并执行"正中靶心。但 2.5.2 正文里的**教育类例外不是我们的路径**（elecon 不是教编程的 App）。真正决定能否上架的是 **Apple Developer Program License Agreement（DPLA）§3.3.2** 给解释型代码（interpreted code）的口子——这是所有"下 JS 跑"的 App 的合规依据。本文把这条口子讲清，并据此给出可上架形态。

同时，issue #4 要求把 imperative requestGraph（ADR-009）与传输底座一并评估。实测下来，**App 内 VPN/隧道与 GPLv3 的上架风险高于 2.5.2 本身**，故一并在此定调。

---

## 2. 决策（Decision）

### 2.1 合规依据：走 DPLA §3.3.2 三段论，不碰 2.5.2 教育类例外

DPLA §3.3.2 允许把解释型代码下载到 App，**只要同时满足**：

> (a) **不改变 App 的主要用途**、不提供与已申报用途不一致的功能；
> (b) **不构成代码 / App 的商店或市场（store / storefront）**；
> (c) **不绕过签名、沙箱或操作系统的其他安全机制**。

**这三条被本文确立为 iOS 端的承重设计约束**——任何 iOS 改动不得破坏其中任意一条（与红线同级，按 git.md §3 走承重路径审查）。elecon 架构天然贴合，且 (a) 上有一张**结构性王牌**：

| 条款 | elecon 的满足方式 | 依据 |
|---|---|---|
| **(a) 不改变主要用途** | 能力集**固定在 App 内**：`contract/capability/registry.json` 枚举全部 capability（grades.list / schedule.week / card.balance / library.loans / notice.list / generic.section），"新增 id 或改语义须走 ADR"。**adapter 只能产出这些已知 schema、渲染由本体完成**——adapter 不引入功能，只把"新数据源"接到"App 内已存在的功能"上。SDUI 保持声明式、受限（ADR-000 §5.1 已主动放弃图灵完备 UI DSL）。 | ADR-000 §2.3/§5.1；`contract/capability/registry.json` |
| **(b) 非代码市场** | **当前绑定决策不变：iOS DEPLOY 无本地导入入口，仅 official adapter 经官方 catalog 分发。** ADR-033 提议的 iOS official 本地导入尚不足以自证“非市场”，须先完成人工/Apple 合规复核；本文接受修订前不得在 iOS 实现。 | 红线 #4/#5；ADR-002 §2.1/§2.5；ADR-033（Proposed） |
| **(c) 不绕过系统安全** | QuickJS 是**纯解释器、无 JIT**（不触 iOS 的 JIT / W^X 禁令）；在 App 沙箱内的 background isolate 执行；wasm/ffi 线性内存内运行，无宿主引用逃逸。 | ADR-008 §2、§3.6 |

**(a) 的关键护栏**：真正的"新功能 / 新 capability / 新卡片类型"**只能随 App 更新发版**，经 `contract/` 改动 + ADR；**adapter 热推只在既有能力集内更新"数据源映射"**。这条把 ADR-000 §2.4"推 adapter 不发版"严格约束在"数据/配置"范畴内，使其落在 §3.3.2(a) 安全区，而非"下载代码改变功能"的雷区。

### 2.2 iOS 首版可上架形态（MVP，绑定决策）

为把首过审复杂度压到最低，**iOS 首版按以下形态提交**：

1. **仅 declarative requestGraph 上架。** imperative（ADR-009，带凭证的 `ctx.fetch`）**推迟到后续版本**——避免首版把 2.5.2 与隐私（指南 5.1.1 数据收集申报）耦合在一起。
2. **bundle 内预置一组基线 adapter。** 让 App **自包含、可离线演示核心功能**；下载仅用于"更新 / 新增数据源"。审核员只测提交的 build——若功能依赖联网拉 adapter 才出现，易被判"功能依赖下载代码"。
3. **iOS 不带 App 内隧道。** 传输默认 = **校内直连 + 引导系统 VPN**（`NEVPNManager` / on-demand），落实 ADR-000 §5.2 已写的降级路径。**不在 iOS release 编入任何 App 内私有隧道目标**（见 §2.3）。
4. **iOS DEPLOY build 仅运行 official 签名 adapter、物理无本地导入入口。** ADR-033 的跨平台 local-import 提议在完成人工/Apple 合规复核并正式修订本文前，不适用于 iOS。

### 2.3 相邻的更高风险，明确立场

issue #4 要求一并评估的两项，上架风险高于 2.5.2，单列结论：

- **App 内 VPN / 隧道（atrust 复刻）** 隧道改走**应用层代理**形态（用户态网络栈在**普通进程内**跑、不建 TUN、不改 OS 路由、对网关仅一条标准出站 **TLS:443**、私有协议封在载荷内——详见 [ADR-003 §2.6](./adr_003_transport.md)），则**不使用 NetworkExtension、不需 VPN entitlement、不触指南 5.4**：从 iOS 视角就是个发出站 HTTPS 的普通 app。**结论修订**：iOS **可**带此类应用层代理隧道；§2.2.3 / §2.3 上一条"iOS 不带 App 内隧道"的封锁**仅适用于包级隧道**。残余风险两点：① 普通 app 后台被挂起 → 无 always-on 隧道（elecon on-demand 取数不需要，可接受）；② 私有协议逆向连校网关的第三方服务合规（指南 5.2.2，小风险，备学校认可学生 VPN 使用的材料缓解）。**注**：是否采此形态、以及净室 / FFI vs 回环的选型，仍为**开放问题**（ADR-003 §2.6 末），须子 ADR + 人工主导，本条不构成落地决策。
- **GPLv3/AGPLv3 与 App Store 分发不相容（atrust 复刻的许可证）。** 众所周知的硬冲突（VLC 案例）：DPLA 的使用限制与 GPLv3 不相容，**GPLv3 代码不得进 iOS 二进制**。注意：**进程 / 模块隔离解决不了"同一可执行包内分发 GPLv3"的问题**——ADR-000 §5.2 写的"边界隔离避免传染"对**链接传染**有效，但对**商店分发相容性**无效。**决策**：iOS 二进制内不含 GPLv3 传输底座。出路三选一：① 取得独立授权；② clean-room 以相容许可证重写；③ iOS 上不带该传输底座（首版采此项）。

  > **2026-08-06 更新（本条对当前候选标的不适用）**：[Probe-002](../probes/probe_002_atrust_tunnel.md) §1 认定候选标的（净室重写的 aTrust 客户端）为**自有 MIT**、依赖树零 GPL 系——即上文出路 ②。故「GPLv3 不得进 iOS 二进制」这条封锁对该标的**不成立**，与上一条的 entitlement 结论合并后，§2.2.3 对 iOS app-tunnel 的两道封锁均已失效。**但这不等于 iOS 可上**：指南 **5.2.2**（逆向私有协议连第三方校网关）尚未评估，Probe-002 §3 明确**不予认定** iOS 可上架。§4 的复评触发器已被触发；当前决策仍是 **iOS 不编入 app-tunnel**（见 [ADR-032](./adr_032_app_tunnel_embedding.md) §2.8 平台门控），首发仅 Android。

### 2.4 审核沟通工具包（Review communication kit）

合规与"让审核员看懂"是两件事。随提交准备：

- **一页《2.5.2 / DPLA 3.3.2 合规声明》**（即 §2.1 三段论），被问时直接引用。当前核心三句仍是：*固定能力集 → adapter 不引入功能；QuickJS 无 JIT → 不绕过系统安全；无侧载入口 → 非代码市场*。ADR-033 若接受，第三句须经人工合规复核后改为：*本地导入只接受项目 official 签名并受在线吊销治理，不构成第三方代码市场*。
- **Reviewer notes**：说明 *adapters are data-source connectors that map external campus endpoints onto a fixed, in-bundle capability set; they cannot add UI or features*。
- **演示账号 + 预置 adapter**，保证审核员在提交 build 上即可走通核心功能。
- 隐私：隐私政策 + App Store 隐私清单（nutrition labels）；申明私密数据不出端 / 仅经校内授权中继（红线 #1–#3）；登录走校方 CAS / SSO。

---

## 3. 已知约束与风险（Consequences）

1. **"推 adapter 不发版"被严格限幅。** 仅在固定能力集内更新数据源映射才安全；**真正的新功能仍须 App 更新**（§2.1(a) 护栏）。这是为合规接受的代价——与 ADR-000 §2.4 的便利相比，边界更窄但更稳。
2. **审核员有自由裁量权。** 即便满足 §3.3.2，仍可能遇主观拒审；缓解靠 §2.4 沟通工具包，必要时走申诉（App Review Board）。这是不可完全消除的残余风险。
3. **依赖 ADR-002 / ADR-009 / ADR-033 的落地状态。** (b)/(c) 论点要求 iOS DEPLOY 不运行未签名 / 非 official adapter。ADR-033 若接受，本地文件入口必须只接受项目 official 签名、在线检查吊销且不形成第三方市场，并先完成人工合规复核。imperative requestGraph 引入 iOS 时仍须重做 2.5.2(a) 自检 + 补 5.1.1 隐私申报。
4. **法律 / 授权事项须外部确认。** VPN entitlement（§2.3）、GPL 授权（§2.3）非工程可独断；正式提交前找 Apple 开发者支持 / 法务确认。本文不构成法律意见。
5. **跨平台不对称。** iOS 因本文约束最严（首版 declarative-only、无隧道）；Android / HarmonyOS 可更早开 imperative / 传输底座。需接受三端能力短期不齐，并在产品文案上说明校外可用性差异（与 ADR-000 §5.2 微信绑定天花板一致）。

---

## 4. 落地清单（指向发布工程，待相关 ADR 接受后逐项小 PR，落地后删除）

> 安全 / 合规敏感项标（人工主导）：

- **构建期断言**：当前 iOS DEPLOY 无本地导入。只有在 **ADR-033 接受 + 人工/Apple 合规复核通过 + 本 ADR 正式修订** 后，才可改为“无 devSideload/未签名路径；设置内入口只汇入 official verifier + 在线治理门”的新断言。
- **预置基线 adapter**：bundle 内打包一组已签名 adapter，首启可离线演示（§2.2.2）。
- **iOS 传输默认**：校内直连 + 系统 VPN 引导（`NEVPNManager` on-demand）；iOS release **不编入** App 内私有隧道目标（§2.2.3 / §2.3）。
- **隐私合规**：隐私政策 + App Store 隐私清单；私密数据不出端声明（§2.4）。
- **审核沟通包**：一页合规声明 + reviewer notes + 演示账号（§2.4）。
- **复评触发**：当 imperative requestGraph（ADR-009）或 App 内传输底座（[ADR-003](./adr_003_transport.md)）拟上 iOS 时，回到本文重做 §2.1 三段论自检与 §2.3 立场。
- 关闭 issue [#4](https://github.com/NanCunChild/elecon/issues/4)，以本 ADR 为结论。
