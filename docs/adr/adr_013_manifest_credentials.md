# ADR-013：manifest `credentials` 声明（凭证引用契约扩展）

- **状态**：已接受（Accepted） 本文改动 `contract/`（manifest schema），触碰红线 #6（契约即承重墙）且服务于红线 #1 的凭证注入路径。按 AGENTS.md §1，**AI 不得独自闭环**：本草案由 AI 起草，**必须经人工 + 安全检查清单审阅后才可接受并实现**。
- **日期**：2026-06-14
- **依赖**：[`adr_001_contract.md`](./adr_001_contract.md)（§5 manifest 规范、§8 版本与兼容治理）、[`adr_009_fetch_credential.md`](./adr_009_fetch_credential.md)（§2.3 凭证作用域草图——本文将其正式纳入 schema）、[`adr_012_credential_store.md`](./adr_012_credential_store.md)（§2.4 `CredentialEntry`——本文的 `credentials.<name>` 即其 `ref` 的指向目标）、[`adr_002_trust_model.md`](./adr_002_trust_model.md)（§2.3 签名覆盖 manifest，使 credentials 声明不可篡改）
- **被依赖**：ADR-009 broker 注入消费本文的 `credentials` 声明；ADR-012 store 的 `ref` 与本文 key 对齐。
- **相关 issue**：[#17](https://github.com/NanCunChild/elecon/issues/17)（B 项：manifest 增 credentials）、[#3](https://github.com/NanCunChild/elecon/issues/3)
- **适用范围**：`contract/manifest.schema.json` 增 **可选** 顶层 `credentials` 块；`tools/` 校验器据此强制的静态规则；与 declarative `requests[].credential` 的命名空间统一。**不含**：凭证如何注入（ADR-009）、凭证值如何获取/存储（ADR-012）、谁有资格注入（ADR-002）。

---

## 1. 背景（Context）

ADR-009 §2.3 给出了 imperative 凭证作用域的 manifest 草图（`credentials.<name>.scope` / `.type`），但**明确声明该草图尚未纳入 `contract/manifest.schema.json`**，须走"独立 issue + PR、与 ADR-001 协调、向后兼容"（红线 #6）。ADR-012 §2.4 定义了核心存储侧的 `CredentialEntry`，其 `ref` 字段注释为"ADR-009 manifest `credentials.<name>` 指向它"——但那个 `credentials.<name>` 在 schema 里**还不存在**。

于是契约出现一个**悬空引用**：

- ADR-009 broker 要"按 manifest 声明的 credential reference 注入"，但 manifest schema 无 `credentials` 字段；
- ADR-012 store 的 `ref` 指向 manifest 的 credential key，但该 key 无 schema 约束；
- `tools/` 校验器要强制"`credentials.scope` ⊆ `network.allow`"（issue #17 B 项），但无字段可校验。

本文把 ADR-009 §2.3 的草图**正式落为 schema**，闭合这个悬空引用，并统一 imperative / declarative 两 requestGraph 的凭证命名空间。**本文只定义"声明契约"，不碰凭证值、不碰注入逻辑**——值与注入分属 ADR-012 / ADR-009。

红线约束：
- #1 凭证值与等价物永不离核心 → **manifest 只含引用名 + 作用域 + 注入方式，绝不含凭证值**。
- #6 契约改动须 ADR + 向后兼容 → 本文为该 ADR，字段**可选**、纯增量。

---

## 2. 决策（Decision，草案）

> 以下为**待审议**取向，非既定事实。每条都需安全审阅确认。

### 2.1 顶层可选 `credentials` 块：引用名 → 作用域 + 注入方式

manifest 增一个**可选**顶层对象 `credentials`，与 `network` 平级。每个 key 是一个**稳定引用名**（credential reference），其值声明该引用的注入作用域与注入方式：

```json
{
  "network": {
    "allow": [
      "https://jw.example.edu.cn/api/*",
      "https://ehall.example.edu.cn/*",
      "https://captcha.example.edu.cn/challenge/*"
    ]
  },
  "capabilities": [
    {
      "id": "example.list",
      "requestGraph": "imperative",
      "emits": { "schema": "elecon.example.list", "schemaVersion": "1.0" }
    }
  ],
  "credentials": {
    "session": {
      "scope": ["https://jw.example.edu.cn/api/*"],
      "type": "cookie"
    },
    "ehall-token": {
      "scope": ["https://ehall.example.edu.cn/*"],
      "type": "header"
    }
  }
}
```

字段定义：

- `credentials.<name>`：`<name>` 是引用名，**即 ADR-012 `CredentialEntry.ref` 的指向目标**。命名约束：`^[a-z][a-z0-9-]*$`（小写起头、kebab）。
- `credentials.<name>.scope`：`string[]`，每条为 uri-template，声明该引用适用的 URL 范围。
- `credentials.<name>.type`：注入方式枚举 `"cookie" | "header"`（对齐 ADR-009 §2.3、ADR-012 §2.4）。`cookie` = 附加 `Cookie` 头；`header` = 附加 `Authorization` 头。

**`credentials` 不含任何凭证值**——只有引用名、作用域、注入方式。值由核心据 `ref` 从安全存储取（ADR-012 §2.4），注入由 broker 完成（ADR-009 §2.1）。manifest 受 ADR-002 §2.3 签名覆盖，故声明不可篡改。

### 2.2 与 ADR-012 `CredentialEntry` 的权威边界

`credentials.<name>`（manifest，签名）与 `CredentialEntry`（核心存储）有字段重叠（`scope` / `type`）。**消歧：manifest 是注入决策的权威来源。**

- broker 决定"是否注入、注入哪个、注入到哪些 URL"**一律以 manifest `credentials.<name>.scope` / `.type` 为准**——因为 manifest 经官方签名（ADR-002），不可被运行时数据篡改。
- `CredentialEntry` 携带的 `scope` / `type` 是**防御性副本 / 取值索引**，**必须与 manifest 一致**；不一致时 broker **以 manifest 为准并告警**（疑似 store 被污染或 adapter 升级后 scope 漂移）。
- `CredentialEntry.value` 是唯一只存在于 store、绝不进 manifest 的字段（红线 #1）。

> 协调项已闭合（ADR-012 §2.4，2026-06-14 决策）：**`CredentialEntry` 保留 `scope`/`type` 作为防御性副本 + 一致性校验基准，但不作为注入依据**；注入决策以已验签 manifest 为唯一权威，store 副本不一致时以 manifest 为准并告警。不删除 store 副本（保留以做一致性检测），但消除了"双源歧义"——权威单一在 manifest。

### 2.3 统一两种 requestGraph 的凭证命名空间

当前 declarative 用 capability 内 `requests[].credential`（一个字符串）引用凭证，但**无处声明该引用的 scope/type**（ADR-001 §6.2）。本文统一命名空间：

- **declarative requestGraph**：`requests[].credential` 的取值**必须**是 `credentials` 块中声明的某个 `<name>`（`tools/` 强制）。核心代取时据该 `<name>` 的 `type` 注入、据 `scope` 校验请求 URL 在作用域内。
- **imperative requestGraph**：broker 据请求 URL 匹配 `credentials.<name>.scope` 决定注入（ADR-009 §2.1）。
- **向后兼容**：`requests[].credential` 是可选字段；**不引用凭证的公开数据请求**（如 `school-xidian` 的 `notice.list`，request 无 `credential`）**无需** `credentials` 块，行为不变。只有当 manifest 实际引用了某 credential 名时，才要求它在 `credentials` 中声明。

### 2.4 `tools/` 校验器强制的静态规则

新增/收紧以下 CI 静态闸门（红线 #6 在校验阶段捕获，而非运行时再判）：

1. **scope ⊆ network.allow**：每个 `credentials.<name>.scope[]` 条目必须被某个 `network.allow` 条目覆盖（子集）。**不能声明注入一个连出口都不允许的 URL**（ADR-009 §2.3 规则 ①）。
2. **scope 重叠消歧**（ADR-009 §2.3b）：对任一可能的请求 URL，按 scope **最长前缀**匹配唯一凭证；若两条 scope 前缀长度**完全相同且语义重叠** → **拒绝通过**（禁止歧义绑定）。
3. **引用闭合**：`requests[].credential`（declarative）引用的名必须在 `credentials` 中声明；声明了但**从未被任何请求/scope 使用**的 credential 给 **warning**（非阻断，可能是预声明）。
4. **type 合法**：`type ∈ {cookie, header}`。
5. **passthrough 合法性**：`network.allow` 中未被任何 `credentials.scope` 覆盖的条目 = **passthrough**（可达不注入，ADR-009 §2.4），**无需**被 scope 覆盖——这是合法的"声明但不注入"，校验器不得因此报错。
6. **sideload 约束联动**：`trustTier: sideload` + 任一 `requestGraph: imperative` 在**官方分发路径**已被拒（ADR-002 §2.6 / `C3_sideload_must_declarative`）；其 `credentials` 块在 release 不生效（无 imperative 注入）。dev 侧载-imperative 的 credentials 仅在 debug build 由 dev 测试凭证填充（ADR-002 §2.5），不经 CI 此闸门。

### 2.5 版本与兼容

- `credentials` 为**可选新增字段** → 纯增量 → **向后兼容**（ADR-001 §3.4「新增可选字段 = 向后兼容」、§8）。
- **不**提升 `manifestVersion` 主版本（增量可选字段不构成破坏性变更）；宿主旧版本遇到未知的 `credentials` 字段应**忽略而非拒绝**（已有 JSON Schema 默认 `additionalProperties` 行为；本文要求宿主对顶层未知字段宽容）。
- ADR-001 §5 manifest 规范须**同步补一节**说明 `credentials`（本文落地时一并改 ADR-001，红线 #6 协调）。

### 2.x 选型对比

| 取向 | 取 | 舍 |
|---|---|---|
| **顶层 `credentials` map + 两种 requestGraph 统一命名空间（建议）** | 单一声明面；imperative/declarative 共用；tools 可静态校验 scope；与 ADR-012 `ref` 一一对应 | declarative 作者多写一个 `credentials` 块（仅当用到凭证时） |
| 凭证声明内联进每个 `requests[]`（仅 declarative 思路延伸） | 局部、就近 | imperative 无 `requests[]` 无处放；scope 难表达多步握手；与 ADR-012 `ref` 对应关系散乱 |
| 维持 ADR-009 §2.3 草图不进 schema | 不改契约 | 悬空引用长期存在，broker/store/校验器都无依据落地——**否决** |

---

## 3. 已知约束与风险（Consequences，草案）

1. **契约承重墙（红线 #6）。** 改 `contract/manifest.schema.json` + ADR-001 §5，须人工审阅 + 向后兼容确认；**不得 AI 独自闭环**。
2. **本文不含凭证值、不含注入逻辑** —— 仅声明契约。值（ADR-012）与注入/脱敏（ADR-009）仍是各自独立的安全敏感 PR，本文是它们的**前置契约**而非替代。
3. **双源 scope/type 的一致性风险**（§2.2）：manifest 与 store 各有一份。缓解：manifest 权威 + store 仅副本/校验；彻底消除双源待 ADR-012 拍板。
4. **统一命名空间是对 declarative 的轻微收紧**（§2.3）：`requests[].credential` 现要求在 `credentials` 声明。向后兼容靠"无凭证请求不受影响"保证；现存 `school-xidian` 不受影响（已核对：其 request 无 `credential`）。
5. **uri-template 匹配语义须与 ADR-009 broker 实现同规格**：scope 子集判定、最长前缀匹配的具体算法（前缀 vs uri-template 展开）须在 broker 与 tools 校验器间**共享同一实现/规格**，否则静态校验与运行时注入会漂移。这是本文与 ADR-009 的接缝，须一并定。
6. **预声明 credential 的 warning 不阻断**（§2.4 规则 3）：允许 manifest 先声明、后续版本再用，避免每次都改 schema 节奏。

---

## 4. 落地清单（待 ADR 接受后，拆成可审查的小 PR，落地后删除）

> 安全敏感项标：

- **schema**：`contract/manifest.schema.json` 增可选顶层 `credentials`（key 命名约束 + `scope: string[]` + `type` 枚举）；顶层未知字段宽容策略。
- **ADR-001 §5 同步**：补 `credentials` 字段说明，标注向后兼容（红线 #6 协调）。
- **`tools/` 校验器**：§2.4 六条静态规则（scope ⊆ network.allow、最长前缀/等长拒绝消歧、引用闭合、type 合法、passthrough 合法、sideload 联动）。与 ADR-009 broker **共享 uri-template 匹配规格**。
- **跨平台 golden**：scope 匹配/消歧的判定在 tools(Node) 与 broker(Dart/Node) 两端一致性测试（与 ADR-002 §3.5 canonicalization 同类跨端一致性要求）。
- **协调 ADR-012**：`CredentialEntry.ref` ↔ `credentials.<name>` 对齐；双源 scope/type 的最终归属（manifest 权威）。
- **协调 ADR-009**：broker 注入消费本 schema；§2.5 的匹配规格统一。
- 测试：合法/非法 manifest 正反例（越界 scope、等长重叠 scope、未声明的 credential 引用、passthrough 不误报）。
