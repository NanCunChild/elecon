# ADR-031：声明式数据流 Seed——公开常量与材料凭证进入句柄空间

- **状态**：**提议（Proposed）** · 2026-07-31 起草；**未授权实现**，须 owner 勾决后方可改契约 / validator / runtime。
- **日期**：2026-07-31
- **依赖**：
  - [`adr_023_declarative_dataflow.md`](./adr_023_declarative_dataflow.md)（`bind`/`compute`/`inject` 句柄模型与 D1–D16——**本文在 bind 前增 `seed` 段**）
  - [`adr_028_declarative_crypto_ops.md`](./adr_028_declarative_crypto_ops.md)（`aes-cbc` 等；D10 key 位须 `ref`——**本文提供 key 的合法来源，不放宽 D10**）
  - [`adr_029_named_and_body_credentials.md`](./adr_029_named_and_body_credentials.md)（§2.3 固定 AES 公开常量须逐案确认；body 注入另属 029）
  - [`adr_013_manifest_credentials.md`](./adr_013_manifest_credentials.md) / [`adr_012_credential_store.md`](./adr_012_credential_store.md)（凭证声明与 store；本文扩材料型 `type`）
  - [`adr_001_contract.md`](./adr_001_contract.md)（§8 双跑 golden）
- **被依赖**（勾决后）：`contract/manifest.schema.json`（`seed` + `credentials.type: material`）；`tools/src/validator/dataflow.ts`（D17–D20 等）；两端 `dataflow` 执行器；`contract/golden/broker/dataflow.json`；`docs/reference/declarative_dataflow_ops.md` / 安全清单。
- **适用范围**：声明式 capability 内，**在 bind 之前**把「已签名公开常量」与「CredentialStore 材料」抬进与 bind 同级的不透明句柄 env，供 `compute`/`inject` 引用。**不含**：放宽 D10 允许 key 字面量、body 模板注入（ADR-029 §2.2）、actuator（ADR-030）、任意 eval / 文件 seed。
- **触及红线**：#1（凭证永不离核心）、#5（adapter 能力面）、#6（契约承重墙）、#10（架构先 ADR）。按 [AGENTS.md](../../AGENTS.md) §1：**seed 求值、credential hydrate、validator、golden 须人工主导 + 安全清单 + ≥1 人工审，AI 不得独自闭环**。

---

## 1. 背景（Context）

ADR-023 的 env 今天只来自：

1. **`bind`**：从响应抽取 → text/bytes 句柄；
2. **`compute`**：封闭 op 产出新句柄。

`credentials`（ADR-013）只服务 **HTTP 注入**（cookie / header / query，含 ADR-029 `headerName`）。**没有**「字面量常量 → 句柄」或「store 值 → 句柄作 compute 输入」的路径。

ADR-028 将 `hmac-sha256` key、`hkdf` ikm、`aes-cbc` key 钉为 **D10：必须 `ref`**，禁止 manifest 字面量密钥进 key 位。结果：

| 需求 | 现状 |
|---|---|
| 西电水电固定 AES key/iv `"1234567812345678"`（probe 证据）作 `aes-cbc` key | D10 禁止字面量 key；bind 又抽不到（非响应字段）→ **无合法路径** |
| store 中的 API secret / 材料密钥作 HMAC/AES 输入 | 凭证只可 HTTP inject，**不能**进 `compute` args |
| ADR-023「同一 credential ref 挂两请求」 | 仅覆盖 HTTP 双挂，**不**覆盖「凭证当 compute 材料」 |

若放宽 D10 允许 key 字面量，审阅负担陡增且易把真密钥写进 signed manifest。正确方向是：**保持 D10，增加受控入口把值变成句柄后再 `ref`**。

公开 vs 秘密仍须分离（ADR-029 §2.3）：固定 AES key 是否属**公开协议常量**须**逐案人工确认**；未确认前不得以 constant 写入 manifest。

---

## 2. 决策（Decision，草案）

### 2.1 新增段：`seed`（在 bind 之前）

声明式 capability 执行序固定为：

```
seed → bind → compute → inject →（发请求 / 脱敏）
```

`seed` 为可选数组；每项产出一个 **text** 句柄（与 bind 的 text 同形，进同一 env `Map`）。

```jsonc
"seed": [
  {
    "var": "aes_key",
    "source": "constant",
    "text": "1234567812345678"
  },
  {
    "var": "aes_iv",
    "source": "constant",
    "text": "1234567812345678"
  },
  {
    "var": "api_secret",
    "source": "credential",
    "ref": "energy-material"
  }
],
"compute": [
  {
    "var": "ct",
    "op": "aes-cbc",
    "args": [
      { "ref": "aes_key" },
      { "ref": "plain" },
      { "ref": "aes_iv" }
    ],
    "params": { "padding": "pkcs7" }
  }
]
```

| `source` | 值来源 | 值是否进 manifest | 产出 |
|---|---|---|---|
| `constant` | 已签名字面量 `text` | 是（公开协议常量） | `text` handle |
| `credential` | 运行期 `CredentialStore` 按 `ref` 解引用 | 否，manifest 只写 ref 名 | `text` handle |

- **`var` 命名空间**：与 bind/compute 共享唯一性（扩展 D3）；seed 名可被后续 compute/inject 引用。
- **拓扑**：seed **无** `from` 请求依赖；全部在 bind 之前求值完毕。bind 不得依赖 seed 以外的新源。compute 可 `ref` seed；inject 同现有规则。
- **类型**：MVP 仅 `text` 句柄。需要 raw bytes 时，仍经现有 `compute`（如后续受控解码 op）；**不**在 seed 直接产 `bytes`，避免扩大类型面。
- **D10 不变**：key / ikm 位仍只接受 `ref`；constant **不得**直接出现在 key 字面量位。seed 的职责是把常量抬成 handle。

### 2.2 凭证：材料型 vs 注入型

现有 `type ∈ {cookie, header, query}` 语义是「scope 命中则 HTTP 注入」。材料密钥（只进 compute）必须分离，避免「同一 cookie 既注入又 seed」的隐式双用途。

**新增**（schema 枚举扩展，向后兼容）：

```text
type: "material"   // 或审议时定名 secret；本文用 material
```

| | cookie / header / query | material |
|---|---|---|
| `decideInjection` / scope 注入 | 是 | **否**（永不命中 inject） |
| `seed.source=credential` | 默认 **禁止**或须显式 flag（见 §2.4） | **允许**且为推荐路径 |
| store 形态 | 同一 `CredentialEntry`（ref、敏感度、at-rest） | 同左 |
| 收割 / 导入 | ADR-026 / 人工 / mint 等既有路径 | 同左；值仍永不离核心 |

**禁止**：adapter、日志、错误消息、公网服务端接触 material 或 seed 句柄字节（红线 #1 / #2）。

### 2.3 公开常量门（逐案数据门，非本 ADR 自动授权）

| 类别 | 处理 |
|---|---|
| 已确认**公开协议常量**（如某校文档/抓包证明的固定 key/iv） | 允许 `seed.source=constant`，值进 signed manifest |
| 未确认 / 熵高 / 像密钥 | **不得** constant；走 `type: material` + 导入或收割 |
| 用户/设备私密 | 永远 credential / material，永不 constant |

Validator **不**判断「是否真公开」；靠 code review + `declarative_dataflow_security_checklist`。可选弱启发式（过长 constant、异常熵）仅 **warning**，不作硬闸。

**IV**：ADR-028 已允许 `aes-cbc` iv 为字面量；亦可 seed 后 `ref`，语义等价。**key 必须** seed→ref（或 bind/compute 派生 ref）。

西电水电 AES key/iv 的 constant 写入：**仍受 ADR-029 §2.3 逐案人工确认**；本 ADR 只提供机制，不替代该确认。

### 2.4 安全不变量（红线 #1）

1. seed / bind / compute 句柄值**永不**回 adapter、日志、用户可见错误（与 ADR-023 一致）。
2. `credential` seed：capability 执行时从 store 解密 → 写入 env → 执行结束**立即丢弃** env；不落盘第二份明文。
3. `constant` 出现在 signed package 内即视为**公开**；禁止用 constant 伪装 secret。
4. 污点：`credential` seed 与 bind 同源 taint；inject + stripEchoes 规则不因 seed 放宽。
5. 缺失 credential / 解密失败 → **fail-closed**（整 capability），不省略 seed 项。
6. seed 节点计入 DAG 节点限额与 handle 字节预算（对齐 D11 / `MAX_*_HANDLE_BYTES`）。
7. 公网哑服务端 **无** CredentialStore；TS 参考实现仅用 golden fixture 模拟 credential seed，**不**真连 store（红线 #2）。

**seed 指向 injectable 凭证**（type 为 cookie/header/query）：MVP **默认拒绝**（validator 硬拦）；若未来需要，须显式 manifest flag + 独立审阅，本文不授权。

### 2.5 Validator 规则（建议编号，勾决后落地）

| 码 | 语义 |
|---|---|
| D17 | 仅 `requestGraph: declarative` 可声明 `seed`（对齐 D1） |
| D18 | `source ∈ {constant, credential}`；constant 须有非空 `text`、无 `ref`；credential 须有 `ref`、无 `text` |
| D19 | `credential.ref` ∈ `manifest.credentials` 且 `type === "material"`（MVP） |
| D20 | `seed.var` 并入 D3 唯一空间；可被 compute/inject 引用；计入 D14 referenced |
| D10 | **不变**：key/ikm 位仍 ref-only |
| D13 / D11 | 信任门与节点限额计入 seed |

`material` 声明：无 scope 或 scope 为空；声明 scope 则 warn 或拒（不参与 inject，避免误导）。

### 2.6 Runtime 接线（Dart 生产 / TS golden）

```
env = evaluateSeed(seeds, { resolveMaterial(ref) })  // 仅客户端有 store
env = applyBind(env, binds, responses…)
env = evalComputeGraph(env, computes, nowMs)
effects = resolveInjections(injects, env)
```

- **Dart**：在 `fulfillDeclarativeRequests` 发首请求前完成 seed；material 缺失错误码与 inject 缺凭证同族。
- **TS**：golden 用 fixture 提供 `credential` 值；与现有 dataflow golden `env` 同形扩展。
- 两端必须双跑一致（ADR-001 §8）。

### 2.7 与既有 ADR 切分

| 能力 | 归属 |
|---|---|
| `seed` 契约 + D17–D20 + 两端执行 + golden | **本文 ADR-031**（扩 ADR-023） |
| `type: material` | 本文；schema 上修订 ADR-013 枚举 |
| 固定 body + `inject.at: body` | ADR-029 §2.2（独立落地） |
| `aes-cbc` 语义 / D10 | ADR-028 **不动** |
| 某常量是否可写 constant | **逐案数据门**（029 §2.3），非本文自动授权 |
| 「同一 credential 挂两 HTTP 请求」 | ADR-023 既有；与 seed 无关 |

---

## 3. 刻意不做（Non-goals）

1. 放宽 D10 允许 key / ikm 字面量。
2. 用 UI `params` / `env.params` 当密钥源。
3. 任意表达式、脚本、从文件/网络读 seed。
4. 服务端公网路径 hydrate 真 credential。
5. seed 产出 `bytes` 或直接 inject 密钥到 HTTP（材料只经 compute 再按既有 inject 规则，若需要）。
6. 在本文授权「injectable 凭证 seed」（见 §2.4）。

---

## 4. 后果（Consequences）

**正向**

- 固定公开协议常量可进 `aes-cbc` 等而不破坏 D10。
- 真密钥保持 store 内，经 material + seed 进 compute，adapter 仍不见值。
- 西电水电等链在 029 body inject 落地后具备完整声明式路径（常量 seed + 028 crypto + 029 body）。

**成本 / 风险**

- 契约与 validator 面扩大；constant 误用为 secret 靠流程与清单，非纯机械门。
- material 与 HTTP 凭证双轨，manifest 作者须选对 type。
- 实现触红线 #1，**必须**安全清单 + 人工审，不得 AI 独自闭环。

**迁移**

- 旧 manifest 无 `seed` / 无 `material`：语义不变。
- 新字段可选、纯增量（红线 #6 向后兼容）。

---

## 5. 落地顺序（勾决后）

1. Owner 接受本文（状态 → Accepted）；确认 §2.2 命名（`material` vs `secret`）与 §2.4 injectable seed 默认拒绝。
2. schema：`seed[]` + `credentials.type` 枚举加 `material`。
3. validator D17–D20 + smoke 负例。
4. TS/Dart `evaluateSeed` + golden（constant + mock material）。
5. Dart store hydrate + fail-closed。
6. 安全清单附录条目 + 人工签收。
7. **另 PR**：逐案确认后的公开 constant（如水电 key/iv）与 ADR-029 body 注入、具体 adapter——**不**与本机制 PR 混提。

---

## 6. 开放问题（勾决时拍板）

1. `type` 最终命名：`material` 还是 `secret`？
2. constant `text` 最大长度硬上限（建议对齐单 handle 上限）？
3. 是否允许 seed 引用「仅 role 标记、无 scope 的既有 header 凭证」作为过渡，或 MVP 只认 `material`？
4. 西电水电 AES key/iv 公开性确认的责任人与记录位置（建议写入该 adapter 的 review 材料，非本 ADR 正文）。

---

## 7. 一句话

用 **`seed` 段**把「signed 公开常量」和「CredentialStore 材料（`type: material`）」抬进与 bind 同级的 handle 空间，**不打开 D10**，不让 adapter 见值；固定 AES key 走 constant（逐案确认），真密钥走 material。
