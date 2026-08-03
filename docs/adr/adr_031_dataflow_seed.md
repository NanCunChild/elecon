# ADR-031：声明式数据流 Seed——公开常量与材料凭证进入句柄空间

- **状态**：**已接受（Accepted）** · 2026-07-31 起草；2026-08-03 owner 锁定决策面并接受（§2 全表 + §6 二进制走字符串编码）。**可据以实现**；seed / material hydrate / validator / golden 仍触红线 #1，按 [AGENTS.md](../../AGENTS.md) §1 **须人工主导 + 安全清单 + ≥1 人工审，AI 不得独自闭环**。
- **日期**：2026-07-31（接受 2026-08-03）
- **依赖**：
  - [`adr_023_declarative_dataflow.md`](./adr_023_declarative_dataflow.md)（`bind`/`compute`/`inject` 句柄模型与 D1–D16——**本文在 bind 前增 `seed` 段**）
  - [`adr_028_declarative_crypto_ops.md`](./adr_028_declarative_crypto_ops.md)（`aes-cbc` 等；D10 key 位须 `ref`——**本文提供 key 的合法来源，不放宽 D10**）
  - [`adr_029_named_and_body_credentials.md`](./adr_029_named_and_body_credentials.md)（§2.3 公开常量数据门；body 注入另属 029）
  - [`adr_026_response_masker.md`](./adr_026_response_masker.md)（masker `credential` 目标可写入 material ref）
  - [`adr_013_manifest_credentials.md`](./adr_013_manifest_credentials.md) / [`adr_012_credential_store.md`](./adr_012_credential_store.md)（凭证声明与 store；本文扩 `type: material`）
  - [`adr_001_contract.md`](./adr_001_contract.md)（§8 双跑 golden）
- **被依赖**：`contract/manifest.schema.json`（`seed` + `credentials.type: material`）；`tools/src/validator/dataflow.ts`（D17–D21 等）；两端 `dataflow` 执行器；`contract/golden/broker/dataflow.json`；`docs/reference/declarative_dataflow_ops.md` / 安全清单；受控 decode op（hex/base64 等，实现期锁定词表，不放宽 D10）。
- **适用范围**：声明式 capability 内，**在 bind 之前**把「已签名公开常量」与「CredentialStore 材料」抬进与 bind 同级的不透明句柄 env，供 `compute`/`inject` 引用。**不含**：放宽 D10 允许 key 字面量、body 模板注入（ADR-029 §2.2）、actuator（ADR-030）、任意 eval / 文件 seed、seed 直接产 `bytes` / 新句柄类型（二进制经字符串编码 + decode op，§2.1 / §6#8）。
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

公开 vs 秘密仍须分离：固定协议常量由 **adapter 作者**在 manifest 中以 `seed.source=constant` 声明（进 signed package = 视为公开）；真密钥走 `type: material` + store，永不进 constant。

---

## 2. 决策（Decision，已接受）

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

- **`var` 命名空间**：与 bind/compute 共享唯一性（扩展 D3）；**禁止** seed 与 bind/compute 同名覆盖。seed 名可被后续 compute/**inject** 引用。
- **拓扑**：seed **无** `from` 请求依赖；全部在 bind 之前求值完毕。compute 可 `ref` seed；**inject 与 bind 同源规则**（见 §2.4.8）。
- **类型**：MVP 仅 `text` 句柄。AES 等对 ASCII 协议常量走现有 UTF-8→bytes（西电 `"1234567812345678"` 足够）。
- **二进制 / 非 UTF-8 密钥**（已拍板）：**不**新增句柄类型、**不**在 seed 直接产 `bytes`。值以 **字符串编码**（hex / base64 等，实现期锁定封闭词表）进入 `constant` 或 `material` 的 text，再经**受控 decode compute op**（如 `hex-decode` / `base64-decode`）产出现有 `bytes` 句柄，供 key/ikm 等 `ref`。decode op 的 key 位语义仍服从 D10（decode 产物是 handle，不是 manifest 字面量密钥）。少类型面、跨端一致成本低；decode 失败 fail-closed + 明确错误（对齐 §2.4.6）。
- **D10 不变**：key / ikm 位仍只接受 `ref`；constant **不得**直接出现在 key 字面量位。seed 的职责是把常量抬成 handle。

### 2.2 凭证：`type: material`（命名已锁定）

现有 `type ∈ {cookie, header, query}` 语义是「scope 命中则 HTTP 注入」。材料密钥必须分离，避免「同一 cookie 既注入又 seed」的隐式双用途。

**新增**（schema 枚举扩展，向后兼容）：

```text
type: "material"
```

| | cookie / header / query | material |
|---|---|---|
| `decideInjection` / scope 注入 | 是 | **否**（永不命中 HTTP 注入） |
| `seed.source=credential` | **禁止**（MVP 硬拦，D19） | **允许**且为唯一合法路径 |
| store 形态 | 同一 `CredentialEntry`（ref、敏感度、at-rest） | 同左 |
| 写入路径 | harvest / masker / mint 等 | **导入 store** + **masker `credential` 目标**（masker 已预留 destination；type/scope 取自 manifest decl） |

- **命名**：勾决用 **`material`**（密码材料），不用 `secret`（与「机密/污点」口语糊在一起）。
- **禁止**：adapter、日志、错误消息、公网服务端接触 material 明文或 seed 句柄字节（红线 #1 / #2）。
- **MVP 只认 `material`**：不设「header 无 scope 过渡」——少一条隐式双用途。

### 2.3 公开常量（adapter 作者写入 manifest）

| 类别 | 处理 |
|---|---|
| **公开协议常量**（网页/客户端字面量、文档写死的固定 key/iv 等） | adapter 作者以 `seed.source=constant` 写入 **signed manifest**；进包即视为公开 |
| 熵高 / 像密钥 / 未确认公开 | **不得** constant；走 `type: material` + 导入或 masker 收割 |
| 用户/设备私密 | 永远 material，永不 constant |

- Validator **不**判断「是否真公开」；靠 adapter review + `declarative_dataflow_security_checklist`。可选弱启发式（过长 constant、异常熵）仅 **warning**。
- **IV**：ADR-028 已允许 `aes-cbc` iv 为字面量；亦可 seed 后 `ref`，语义等价。**key 必须** seed→ref（或 bind/compute 派生 ref）。
- 西电水电 AES key/iv 等：由 **该 adapter 作者**写入 manifest constant；公开性与 review 材料归 adapter 侧，**非**本 ADR 正文义务。本 ADR 只提供机制。

### 2.4 安全不变量（红线 #1）

1. seed / bind / compute 句柄值**永不**回 adapter、日志、用户可见错误（与 ADR-023 一致）。
2. `credential` seed：capability 执行时从 store 解密 → 写入 env → 执行结束**立即丢弃** env；不落盘第二份明文。
3. `constant` 出现在 signed package 内即视为**公开**；禁止用 constant 伪装 secret。
4. **污点**：
   - `credential` seed → **tainted**（与 bind 抽取敏感值同源）；
   - `constant` seed → **不 taint**（公开协议常量）；
   - inject + stripEchoes 规则不因 seed 放宽；污点自动围栏后补时以此为钩。
5. 缺失 material / 解密失败 → **fail-closed**（整 capability），不省略 seed 项。
6. **字节预算与超限（fail-closed + 明确错误）**：
   - seed 节点计入 DAG 节点限额与 handle 字节预算（对齐 D11 / `MAX_*_HANDLE_BYTES`）。
   - **声明/解析期**（validator + runtime 装载 seed）：constant `text` 超限、material 解出值超限 → **明确错误码**（如 `seed_handle_too_large` / D21），fail-closed，便于 adapter 开发定位。
   - **封闭 op 计算中**句柄产物超限：同样 fail-closed 并报错。在**信任环境**（官方签名 + 人工审）下，此类错误的存在可能构成**长度/失败预言机**；**本 ADR 明确将其标为可接受残余风险**——优先开发可诊断性，与 ADR-023 §2.5 / ADR-028 已接受的长度预言机类同级，不新开侧信道面，不因「消预言机」而静默截断或模糊错误。
7. 公网哑服务端 **无** CredentialStore；TS 参考实现仅用 golden fixture 模拟 credential seed，**不**真连 store（红线 #2）。
8. **inject 与 bind 同源**：seed 产出的句柄可被 `inject` 引用，规则与 bind 句柄相同（目标 / stripEchoes / 脱敏）。**`type: material` 本身仍永不经 `decideInjection` 做 HTTP 直注**；若要把材料相关结果送出，只经 seed→（compute）→inject 的句柄路径，且仍受既有 inject 约束。
9. **seed 指向 injectable 凭证**（cookie/header/query）：MVP **硬拒**（D19）；未来若需要须显式 flag + 独立审阅，本文不授权。

### 2.5 Validator 规则（编号，实现时落地）

| 码 | 语义 |
|---|---|
| D17 | 仅 `requestGraph: declarative` 可声明 `seed`（对齐 D1） |
| D18 | `source ∈ {constant, credential}`；constant 须有非空 `text`、无 `ref`；credential 须有 `ref`、无 `text` |
| D19 | `credential.ref` ∈ `manifest.credentials` 且 **`type === "material"`**（MVP 只认 material；injectable type 硬拒） |
| D20 | `seed.var` 并入 D3 唯一空间；可被 compute/**inject** 引用；计入 D14 referenced；禁止与 bind/compute 撞名 |
| D21 | constant `text` 字节长度 ≤ 单 handle 上限（与 `MAX_*_HANDLE_BYTES` 同源）；超限 error（非 warn） |
| D10 | **不变**：key/ikm 位仍 ref-only |
| D13 / D11 | 信任门与节点限额计入 seed |

`material` 声明：无 scope 或 scope 为空；声明非空 scope → **error 或 warn**（不参与 inject，避免误导；落地时取 error 更清晰）。

### 2.6 Runtime 接线（Dart 生产 / TS golden）

```
env = evaluateSeed(seeds, { resolveMaterial(ref) })  // 仅客户端有 store
env = applyBind(env, binds, responses…)
env = evalComputeGraph(env, computes, nowMs)
effects = resolveInjections(injects, env)  // seed 句柄与 bind 同源可 inject
```

- **Dart**：在 `fulfillDeclarativeRequests` 发首请求前完成 seed；material 缺失错误码与 inject 缺凭证同族；超限错误码可诊断、fail-closed。
- **TS**：golden 用 fixture 提供 `credential` 值；与现有 dataflow golden `env` 同形扩展。
- 两端必须双跑一致（ADR-001 §8）。

### 2.7 与既有 ADR 切分

| 能力 | 归属 |
|---|---|
| `seed` 契约 + D17–D21 + 两端执行 + golden | **本文 ADR-031**（扩 ADR-023） |
| `type: material` | 本文；schema 上修订 ADR-013 枚举 |
| material 写入 store | 导入路径 + **ADR-026** masker `credential` 目标（manifest 声明 `type: material`） |
| 固定 body + `inject.at: body` | ADR-029 §2.2（独立落地） |
| `aes-cbc` 语义 / D10 | ADR-028 **不动** |
| 某常量是否写 constant | **adapter 作者 + review**；机制由本文提供 |
| 「同一 credential 挂两 HTTP 请求」 | ADR-023 既有；与 seed 无关 |

---

## 3. 刻意不做（Non-goals）

1. 放宽 D10 允许 key / ikm 字面量。
2. 用 UI `params` / `env.params` 当密钥源。
3. 任意表达式、脚本、从文件/网络读 seed。
4. 服务端公网路径 hydrate 真 credential。
5. seed 直接产出 `bytes`，或引入 byte-array 等新句柄类型（二进制走字符串编码 + decode op，§2.1）。
6. 授权「injectable 凭证 seed」（cookie/header/query → seed）。
7. `type: material` 经 `decideInjection` 做 HTTP 直注。
8. 为实现「消预言机」而静默截断句柄或模糊超限错误（与 §2.4.6 可接受风险对立）。

---

## 4. 后果（Consequences）

**正向**

- 固定公开协议常量可进 `aes-cbc` 等而不破坏 D10。
- 真密钥保持 store 内，经 material + seed 进 compute /（可选）inject 句柄路径，adapter 仍不见值。
- material 写入路径完整：人工导入 + masker 收割（与 026 预留衔接）。
- 西电水电等链在 029 body inject 落地后具备完整声明式路径（常量 seed + 028 crypto + 029 body）。

**成本 / 风险**

- 契约与 validator 面扩大；constant 误用为 secret 靠流程与清单，非纯机械门。
- material 与 HTTP 凭证双轨，manifest 作者须选对 type。
- **句柄封闭计算超限 fail-closed 的失败预言机**：在信任环境中标为**可接受残余风险**（§2.4.6），换取明确错误与可调试性。
- 实现触红线 #1，**必须**安全清单 + 人工审，不得 AI 独自闭环。

**迁移**

- 旧 manifest 无 `seed` / 无 `material`：语义不变。
- 新字段可选、纯增量（红线 #6 向后兼容）。

---

## 5. 落地顺序

1. ~~Owner 接受本文~~（**2026-08-03 Accepted**）。
2. schema：`seed[]` + `credentials.type` 枚举加 `material`。
3. validator D17–D21 + smoke 负例（含 injectable seed 硬拒、constant 超限、material 无/有 scope）。
4. TS/Dart `evaluateSeed` + golden（constant + mock material + inject 引用 seed）。
5. 受控 decode op（hex/base64 等封闭词表）+ golden；产物为现有 `bytes` handle，供 crypto key 位 `ref`。
6. Dart store hydrate + fail-closed；masker commit 写入 `type: material` 的联调用例（可与 026 C2 接线同轨或紧随）。
7. 安全清单附录条目 + 人工签收（含 §2.4.6 预言机接受声明）。
8. **另 PR**：具体 adapter 的 constant（如水电 key/iv）与 ADR-029 body 注入——**不**与本机制 PR 混提。

---

## 6. 已拍板项（2026-08-03）

| # | 问题 | 结论 |
|---|---|---|
| 1 | `type` 命名 | **`material`** |
| 2 | constant / handle 长度上限 | 对齐单 handle 上限；**超限 fail-closed + 明确错误**；op 计算超限的失败预言机为**可接受风险**（信任环境优先可诊断） |
| 3 | credential seed 合法 type | MVP **只认 `material`** |
| 4 | 水电等公开字面量 | **adapter 作者**写入 manifest constant；review 归 adapter 侧 |
| 5 | material 来源 | **允许导入 store**；**允许 masker 写**（destination 已预留） |
| 6 | seed 句柄与 inject | **允许**，与 bind **同源规则** |
| 7 | 污点 | `credential` seed = taint；`constant` = 不 taint |
| 8 | 非 UTF-8 / 二进制密钥 | **字符串编码表示**（hex / base64 等封闭词表）→ `text` handle → 受控 decode op → 现有 `bytes`；**不**新增句柄类型、不 seed 直接产 bytes |

决策面无悬置开放点；实现期仅锁定 decode op 词表与错误码命名（不改本文方向）。

---

## 7. 一句话

用 **`seed` 段**把「signed 公开常量」和「CredentialStore **material**」抬进与 bind 同级的 handle 空间，**不打开 D10**；constant 由 adapter 作者写入，真密钥走 material（导入或 masker）；二进制经字符串编码 + decode op；句柄可 inject 且污点分轨；超限明确 fail-closed（计算期失败预言机可接受）。
