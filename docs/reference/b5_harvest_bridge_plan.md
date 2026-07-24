# B5 实现计划 · 耐久 cookie 收割桥接 → ADR-012 库

> 状态：**已落地（2026-07-14）**——`harvest.ts` / `harvest.dart`（`decideHarvest`/`harvestInto`）+ golden 向量
> + 冒烟测试入库、CI 双跑；§8 开放点实现时已定。本文留作**实现依据 / 历史**。实现属 🔒 安全敏感承重路径
> （红线 #1：凭证入核心库），按 [AGENTS.md](../../AGENTS.md) §1 **AI 不得独自闭环**。
> 依据：[ADR-009](../adr/adr_009_fetch_credential.md) §2.4（收割判据 b + 匹配算法）·
> [ADR-012](../adr/adr_012_credential_store.md) §2.2/§2.4/§2.5 · [Track B 计划](./track_b_imperative_runtime_plan.md) §4。
> 前置：B4 cookie jar（#37 TS / #38 Dart）· 凭证存储原型（#32/#33）。

## 0. 这件事是什么

单次执行结束时，核心把 jar **origin 区**里「manifest 显式声明为凭证」的耐久 cookie
**收割**进 ADR-012 凭证库，供后续执行注入复用（免每次重登）。瞬态 cookie（挑战 nonce、
握手中途 token、ephemeral 区）**一律丢弃**。

这是 fetch「会话复用」闭环的最后一环：B4 在执行内攒 cookie，B5 把其中耐久的桥进库，
下次执行 B1/B6 再从库注入。

## 1. 范围

**含**：
- 纯决策 `decideHarvest(originCookies, manifestView) → HarvestPlan`：判定 origin 区哪些
  cookie 该收割、归属哪个 ref（判据 b + RFC 6265 收割方向匹配）。
- 桥接 `harvestInto(plan, store, ctx)`：把 plan 写入 `CredentialStore.put`（构造
  `CredentialEntry`，注入权威字段以 manifest 为准、store 副本为防御性）。

**不含**（划走）：
- **收割触发时机**（执行结束调用点）属 **B6 运行时**——B5 只提供纯决策 + 桥接函数，不接线。
- ephemeral 区——结构上不可达收割（B4 `harvestView()` 只返回 origin 区，栅栏 3）。
- WebView 登录收割（ADR-012 §2.2，另随客户端落地）。
- at-rest 加密 / OS keystore（ADR-012 §2.1 上线前硬门槛，原型仍内存明文）。

## 2. 模块拆分（TS 权威 + Dart 镜像）

| 文件 | 职责 | 纯/有态 |
|---|---|---|
| `server/src/runtime/broker/harvest.ts` | `decideHarvest`（纯）+ `harvestInto`（桥接到 store） | 纯决策 + 薄桥接 |
| `server/src/runtime/broker/harvest.smoke.ts` | golden 双跑 + 与 CredentialStore 集成（收割→get 可注入） | — |
| `contract/golden/broker/harvest.json` | 共享向量（钉两端 decideHarvest 一致） | — |
| `client/lib/core/broker/harvest.dart` + `client/test/broker_harvest_test.dart` | Dart 镜像，读同一 golden | — |

## 3. `decideHarvest` 语义（判据 b + 收割方向匹配）

输入：`originCookies: JarCookie[]`（B4 `harvestView()` 输出）+ `view: BrokerManifestView`。

```
decideHarvest(originCookies, view) → HarvestPlan = Array<{ ref: string; cookie: HarvestedCookie }>
```

算法（ADR-009 §2.4 第 122–124 行）：
1. 遍历 `view.credentials` 中 `type === "cookie"` 的每个 `(ref, decl)`。
2. 对 decl.scope 每条前缀解析 `(scheme, host, pathPrefix)`，构造代表性 URL
   `scheme://host + pathPrefix`。
3. 对每个 origin cookie，若 `matchCookieForSend(cookie, scopeUrl)`（复用 B4 cookie-match：
   domainMatch(scopeHost, cookieDomain) ∧ cookiePath 为 scope pathPrefix 前缀）→ 命中该 ref。
4. 命中的 cookie 进 plan（归该 ref）；未被任何 cred ref 命中的 cookie → 瞬态，丢弃。

`type === "header"` 的 ref 不参与 cookie 收割（其凭证来自 header 注入，非 jar）。

## 4. golden 向量（`harvest.json`，约 8 例）

- harvest_declared_session：origin 有 `JSESSIONID`，scope 命中 → plan 含该 cookie 归 ref。
- drop_undeclared：origin cookie 不被任何 cred scope 命中 → 不收割。
- drop_header_type_ref：cred 为 type:header → 该 ref 不收 cookie。
- domain_parent_match / path_prefix_match：收割方向匹配边界（cookie 域更宽才收）。
- nomatch_path_deeper：cookie path 比 scope 更深 → 不发往 scope → 不收。
- multi_scope_ref：一 ref 多 scope，任一命中即收。
- **multi_cookie_one_ref**：scope 命中**多个** cookie 名 → 见 §8 开放点 #1（行为待定）。

## 5. 桥接 `harvestInto` → CredentialStore

对 plan 每项构造 `CredentialEntry`（ADR-012 §2.4）：
- `ref` = plan.ref；`type`/`scope` = manifest decl（注入权威以 manifest 为准，store 为防御性副本）；
- `value` = 收割的 cookie 值（见 §8 #1：单 cookie 还是序列化多 cookie）；
- `schoolId` = 执行上下文提供；`acquiredAt` = now；`status` = active；
- `expiresAt` = 见 §8 #2（须 Max-Age/Expires，但 B4 当前未捕获）。
- 同 ref 已存在 → `put` 覆盖（会话轮换）。

## 6. 安全清单（PR body，🔒 人工逐项）

- [ ] **只收 manifest 声明 ref 的 cookie**（判据 b），未声明一律丢弃——绝不把瞬态 token 入库
- [ ] ephemeral 区结构上不可达（输入仅 `harvestView()` origin 区）
- [ ] 收割方向匹配正确（scope host domain-match cookie Domain；cookie Path 为 scope 前缀）
- [ ] 注入权威唯一在 manifest，store type/scope 为防御性副本
- [ ] 收割值为凭证等价物，全程仅核心内流转，绝不回交 adapter
- [ ] 原型内存明文限制已显著标注，绝不收割真实凭证入原型（红线 #1/#8）

## 7. PR 拆分（建议拆两个，同 B4 节奏）

- **PR-B5①（TS）**：`harvest.ts` + golden + smoke（含 CredentialStore 集成）。
- **PR-B5②（Dart 对齐）**：镜像，读同一 golden。

## 8. 开放点拍板记录（2026-06-16）

| # | 议题 | 决定 |
|---|---|---|
| 1 | **ref ↔ cookie 名映射缺失** | **路线 a**：`ref.value` = 该 ref scope 命中的**全部** origin cookie 序列化串（`n1=v1; n2=v2`，RFC 6265 §5.4 发送序：path 长者先、同长按名）；注入时（B6）原样附加为 Cookie 头。**无契约改动**（不碰红线 #6）。精度不足时（需 per-cookie 区分）再评估路线 b（manifest 扩 `cookieNames`，届时另开 ADR）。 |
| 2 | **expiresAt 来源** | **路线 b（跑通优先）**：一律 `expiresAt=null`（session 语义），靠 ADR-012 §2.5 的 401-重登兜底。精确过期需扩 B4 capture（Max-Age/Expires），**另开件**，不在 B5。 |
| 3 | **schoolId 来源** | 由 B6 运行时经 `HarvestContext.schoolId` 传入 `harvestInto`（执行上下文）。 |

## 9. 实现状态

- **PR-B5①（TS）**：#40 —— `harvest.ts`（`decideHarvest` + `harvestInto`）+ golden 10 例 + smoke。
  复核改进：`decideHarvest` 内置 `source==='origin'` 守卫（纵深防御栅栏 3，不信任上游）；
  父域共享 cookie 多 ref 收割行为由 golden 钉死。
- **PR-B5②（Dart 对齐）**：待 #40 合并后开。
