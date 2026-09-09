# 归档：ADR-003 §2.5 GPL 许可证隔离方案（已被 MIT 选型取代）

- **文档性质**：被取代的方案分析（只读档案）
- **归档日期**：2026-09-09
- **决策权威**：[`adr_003_transport.md`](../adr/adr_003_transport.md) §2.5 与
  [`adr_032_app_tunnel_embedding.md`](../adr/adr_032_app_tunnel_embedding.md) §2.1。**本文不是决策源。**
- **落地与签收状态**：见 [`adr/README.md`](../adr/README.md)。**本文不记录状态。**

> **为什么归档而非删除**：`app-tunnel` 的标的已定为 **Hermes（自有 MIT）**，链接传染与商店分发不相容
> 两个问题同时消失，整张 GPL 分平台矩阵不再适用。但**它没有变成错的，只是不再适用于当前标的**——
> 若 Hermes 落空、回到 zju-connect（AGPLv3）或任何 GPL 系实现，下面的分析原样有效。删掉等于
> 半年后重做一遍。

---

## 1. 两个常被混淆的问题（原 §2.5 开篇）

- **① 链接传染**：GPL 代码静态/动态链进主二进制 → 主程序被传染。
  **隔离手段：进程边界 / 独立分发单元 + 窄 IPC**——GPL 实现跑在单独进程或单独可分发组件里，
  主 App 经 IPC 调用，不链接其符号。
- **② 商店分发相容性**：GPLv3 与 App Store DPLA 使用限制不相容（VLC 案例）。
  **进程隔离治不了这一层**——只要 GPL 二进制随**官方商店渠道**分发即冲突。

## 2. 分平台矩阵

| 平台 | `app-tunnel`(GPL) 可行性 | 形态 |
|---|---|---|
| **iOS / App Store** | **不可**（分发不相容 + entitlement 门槛） | 不编入；`direct` + `system-vpn` |
| **Android**（Play / 侧载） | 可，但须履行 GPLv3 §6：提供对应源码、不附加限制 | 独立进程 sidecar / 独立分发组件（独立 APK 或 Service）+ 窄 IPC |
| **桌面** | 类 Android，按各自商店规则 | 同上 |
| **OHOS** | 开发优先级低，待后续确认；若 Flutter 无法覆盖 OHOS 的 VPN/隧道 API，再考虑独立技术栈与 QuickJS FFI 方案 | 暂同桌面；具体形态待定 |

## 3. 三条根本出路（与 ADR-010 §2.3 一致，按建议排序）

1. **默认：官方分发的二进制不带 GPL transport**；`system-vpn` 引导全平台兜底（首选，零法律面）。
2. **clean-room 以相容许可证重写** atrust 协议客户端——**唯一**能让 in-app tunnel 上 iOS 的路径；
   成本最高，按需求强度决定。
3. **取得独立/双授权**，或把 GPL transport 作为**用户自行安装的独立组件**（不随官方包分发，
   用户侧 sideload，类比引导安装官方 atrust 客户端）。

**当时的结论取向**：首版只做 `direct` + `system-vpn`；`app-tunnel` 作为后续、平台门控、
经三件套探针、以「进程隔离 + 平台分发矩阵」分别处理的可选档。

---

## 4. 为什么它不再适用（2026-09-09）

Probe-002 的三件套探针查明标的 **Hermes 自有 MIT、依赖树零 GPL 系**，
[`adr_032`](../adr/adr_032_app_tunnel_embedding.md) §2.1 据此**采净室自研（Hermes），不接入
zju-connect**（后者 AGPLv3，仅作逐行对照的参考实现，不作依赖）。

于是：

- **①链接传染**消失 → 可用进程内 FFI（ADR-032 §2.2），不必进程隔离。
- **②商店分发不相容**消失 → **iOS 重新可行**。叠加 ADR-003 §2.6 已为**形态 B**（应用层代理隧道）
  解除 NetworkExtension / entitlement / 指南 5.4 的封锁，iOS 的 `app-tunnel` 两道门都开了。
- 上面「三条出路」中的第 2 条即为实际所选，只是代价被探针证明低于预期。

**放行条件已满足（2026-09-09 核实）**：ADR-032 §2.1 要求「Hermes 仓补 `LICENSE` 文件
（当时仅 `Cargo.toml` 一行声明，不构成分发许可，红线 #9）」——现已补全为 MIT 全文
（`Cargo.toml` 亦声明 `license = "MIT"`）。

**仍未解除的**：ADR-032 整体仍为 **Proposed**；其 §2.6 要求的「表达性选择复现审查」
（抽查 Hermes 与 zju-connect 在同一协议点的实现，确认相似性来自协议约束而非代码表达复制）
**须由人工完成，AI 不得自评**。该审查未完成前，不得合并任何隧道实现代码。
