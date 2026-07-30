# Response Masker 重构与迁移计划

> **状态：随 ADR-026 提议，暂不实施。** 本文展开 Broker 响应凭证收割与投影层的候选工程方案。ADR-026 经 owner 人工安全评审并接受前，不授权修改 Broker、契约、签名 bundle 或正式 adapter。

## 1. 目标

Response Masker 不再只是交付前字符串替换器。它把学校响应中的非标准凭证敏感值从 adapter 逻辑收回可信核心，形成以下闭环：

```text
raw response
  -> signed response policy
  -> capture credential-sensitive value
  -> validate destination and scope
  -> project adapter-visible response
  -> commit credential or opaque handle under bounded semantics
  -> broker-controlled injection
```

重构完成后：

- adapter 只归一化学校业务数据，不自行取得、保存或注入凭证；
- Credential Store 承接跨执行凭证；
- ADR-023 opaque handle 承接单次执行内跨请求材料；
- 仅需清除的敏感回显由核心直接丢弃；
- declarative、imperative 和 actuator action 共用同一响应交付防火墙；
- 字段漂移导致 capability fail-closed，等待 adapter 与 policy 同步热更新。

## 2. 信任边界

### 2.1 两个不可互替的责任

**社区与人工签名门负责分类。** reviewer 根据协议证据、脱敏 fixture 和后续请求行为判断字段是否为 credential-equivalent，并批准 adapter 代码与 `masker.json` 的组合。

**Broker 负责执行。** 对已签名规则命中的值，Broker 保证 adapter 看不到 Masker 前响应、不能关闭规则、不能读取 Credential Store 或解引用 opaque handle。

签名证明“这份分类和代码被官方认可”，不意味着 adapter 自动获得原值读取权限。Broker 不尝试从任意 body 中自动证明什么是秘密。

### 2.2 不配合 adapter 的限制

若 official adapter 故意漏报敏感字段并从投影响应中自行正则提取，通用运行时无法可靠区分该字段与普通业务 ID。该风险由以下治理承接：

- adapter 贡献规范禁止自行提取或跨请求传递凭证；
- scanner 把高风险正则、token/session/cookie 字段、认证 header 和跨请求值传递提交人工复核；
- 门 1 检查代码、fixture、observation 和 policy；
- 门 2 用测试账号执行 raw-to-delivered replay；
- 离线签名者核对安全清单后才触碰签名；
- 已签绕过在发现后进入 revocation / `minVersion`。

scanner 只负责发现候选，不以关键词或熵自动裁定秘密，也不得成为拒绝普通业务字段的唯一依据。

## 3. 策略文件

每个需要响应凭证处理的 adapter 带独立 `masker.json`：

```text
school-foo/
  manifest.json
  masker.json
  index.js
```

审核材料不进入发布 bundle：

```text
review/
  fixtures/raw/
  fixtures/delivered/
  security-observations.json
```

`masker.json` 已可被现有 signer 的 `.json` include 规则纳入 digest；新增工作是 schema、唯一文件名、验签后加载、host/version gate、validator、policy diff 和 runtime 执行，而不是扩展 digest 文件后缀。

ADR-026 接受时须同步修订 ADR-018 的 bundle 内容说明，把 `masker.json` 列为可选签名运行时文件；旧 host 必须通过版本门拒绝依赖该文件的新 bundle，不能验完 digest 后忽略未知策略继续加载。

候选规则草图：

```json
{
  "schemaVersion": 1,
  "rules": [
    {
      "id": "aircon-session-token",
      "match": {
        "capability": "climate.devices",
        "method": "POST",
        "urlScope": "https://login.example.edu/aircon/session"
      },
      "capture": {
        "source": "json",
        "path": "$.data.accessToken",
        "required": true,
        "exactly": 1,
        "destination": {
          "kind": "credential",
          "ref": "aircon-session"
        }
      },
      "project": "replace"
    }
  ]
}
```

该草图不是已接受契约。最终 schema 须封闭以下维度：

- `match`：capability、method、final URL scope，可选 declarative request key；
- `capture`：header、受限 JSONPath、受限 regex capture；
- `destination.kind`：`credential | handle | redact`；
- `destination.ref`：只引用 manifest credential 或静态 dataflow handle 声明；
- `handle` destination 引用既有 `bind[].var`，其 source/selector 以 `bind` 为唯一真相，Masker 规则不得再声明第二份 path/pattern；
- cardinality：首期默认且建议只允许 `exactly: 1`；
- `project`：header 删除或固定 sentinel 替换，不允许自定义 replacement；
- 文件大小、规则数、selector 长度、body 大小和提取值大小上限。

## 4. 交付事务

### 4.1 统一入口

任何 marshal 进 QuickJS 的网络响应都必须经过唯一 delivery API。生产调用方不得直接构造 adapter-visible `ProcessedResponse`。

候选上下文至少包含：

- 已验签 adapter identity 和 digest；
- capability 与 requestGraph；
- request key 或 action id；
- method 和 final URL；
- 已验签 response policy；
- raw status、headers 和 body；
- Credential Store transaction / execution-local handle table。

Dart 与 TS 均从现有 `processResponse`、declarative host 和 imperative bridge 收敛到该 API，不能分别挂 nullable Masker callback。

### 4.2 顺序

```text
Transport raw response
  -> redirect / CookieJar / query harvest
  -> response policy match
  -> capture from raw headers/body
  -> validate cardinality/type/size/destination/scope
  -> build projected response
  -> strip invalid entity metadata
  -> commit one credential and staged handles under bounded semantics
  -> strip downstream injection echoes
  -> adapter-visible response
```

Cookie、redirect 和已声明 query harvest 保持更上游，因为它们是通用结构化凭证处理。Masker 不能放进 Transport，Transport 不应知道 adapter identity、capability 或 Credential Store 目标。

### 4.3 原子性

Capture、Validate、Project、Commit 任一步失败时：

- adapter 不收到响应；
- 下游请求不发送；
- 不留下只有部分规则成功的 handle table；
- Credential Store 不出现无法追溯的多 ref 半更新；
- 错误只进入不含秘密的宿主诊断。

首期每个响应最多包含一个 `destination.kind: credential` 持久写。实现先在临时事务中完成全部提取、投影和 handle 预算校验，再对该 credential 执行一次安全存储原子替换，最后以不可失败的内存 generation swap 激活 staged handles。安全存储成功后若进程崩溃，可以只留下新 credential 而不交付本次响应；这是安全侧偏差，下次执行按正常生命周期处理。

不得用补偿性“写回旧值”伪造跨后端事务，因为崩溃窗口仍存在。未来若一个响应必须更新多个持久 credential ref，先为 Credential Store 设计 generation/CAS 和崩溃恢复，再扩展规则上限。

## 5. 失败语义

默认规则全部是 required：

| 情况 | 行为 |
|---|---|
| policy schema 非法或越界 | adapter 拒载 |
| 必需 selector 未命中 | capability fail-closed |
| JSON / text 解析失败 | capability fail-closed |
| 命中数量异常 | capability fail-closed |
| 类型、大小或 scope 不符 | capability fail-closed |
| response projection 失败 | capability fail-closed |
| credential / handle commit 失败 | capability fail-closed |
| Masker 内部异常 | capability fail-closed |

字段漂移时旧 adapter 本来无法正确形成后续认证请求，因此不以交付原 body 换取表面可用性。adapter 代码、`masker.json`、fixture 与版本治理一起更新。

首期不建议提供 optional credential capture。若未来确有“存在则清除、不存在不影响功能”的纯 `redact` 案例，须新增封闭语义，且不得影响是否发送请求、credential 注入或 adapter 可观察分支。

## 6. Selector 与投影

首期控制在两类：

| 来源 | Selector | Capture | Projection |
|---|---|---|---|
| header | 大小写不敏感固定头名 | 原始 header value | 删除整个头 |
| JSON | ADR-023 同语义的受限 JSONPath | 单个标量 | 固定 sentinel |

第二期按真实案例增加受限 text regex。HTML selector 只有在脱敏真实案例证明 JSON/regex 不足，且 Dart/TS parser 与序列化 probe 通过后再提。

固定 sentinel 建议为 `__ELECON_MASKED__`。规则不得提供自定义 replacement。body 改写后至少删除 `Content-Length`、`Content-Encoding` 和 `ETag`；是否保留 `Content-Type` 及 charset、如何处理压缩 body 和非法编码，必须由共享 golden 固定。

## 7. 核心目标

### 7.1 Credential Store

`destination.kind: credential` 必须引用 manifest 已声明 credential：

- credential ref 存在且类型兼容；
- 已验签 Masker rule 的 source URL scope 是 manifest `network.allow` 的子集；该“source scope -> credential ref”绑定就是首期 acquisition 授权，不要求 source 与 injection scope 相同；
- capture 规则不能扩大 injection scope；
- 更新策略明确覆盖、版本、过期和撤销行为；
- 原值不进入 adapter、fixture、日志、trace 或异常。

首期持久 capture 仅在 client-direct 启用。TS Broker 仍双跑 Capture / Project 和 execution-local handle；public 不处理私密响应，campus-relay 在另行确定零落盘凭证方案前不得提交持久 credential。

### 7.2 Opaque handle

`destination.kind: handle` 只存于当前 execution。为避免与 ADR-023 `bind` 形成两套 selector，敏感 handle 规则引用既有 `bind[].var`：

- 复用 ADR-023 的 bytes/text 类型、64 KB 单值上限和全 DAG 预算；
- selector 和 source request 仍以 `bind` 为唯一真相，Masker 只增加 credential-sensitive 分类和 projection；
- Broker 在同一次 raw extraction 中建立 staged handle 并完成 projection，不执行第二次提取、不重复计量；
- 只流向静态 `inject.into/at/name`；
- 不进入 adapter responses；
- 产生 handle 的源响应必须同步投影；
- 执行结束全部清除。

### 7.3 Redact only

`destination.kind: redact` 不保存原值，仅投影删除。它适用于已确认敏感回显，而不是 adapter 后续功能依赖的凭证。

## 8. 空调小例子

聚好联空调使用 `x-access-token`，ADR-029 将其声明为具名 header credential：

```json
"aircon-session": {
  "scope": ["https://gxkt.juhaolian.cn/*"],
  "type": "header",
  "headerName": "x-access-token"
}
```

候选闭环：

```text
假设绑定/登录响应存在 $.data.accessToken
  -> capture destination credential:aircon-session
  -> Credential Store 原子更新
  -> $.data.accessToken 替换为固定 sentinel
  -> adapter 解析设备列表，不读取 token
  -> climate.status / climate.command
  -> Broker 在 gxkt.juhaolian.cn scope 注入 x-access-token
```

这个例子只验证凭证取得与命名 header 注入。`climate.command` 的用户手势、单 mutation、禁重试、状态核验和设备标识保护仍完全由 ADR-030 决定。

该 JSONPath 是 synthetic 候选 fixture，不代表已确认的聚好联协议事实；真实上游来源和刷新流程仍须人工探针确认。ADR-029/030 均为 Proposed，只有相关 ADR 分别接受后，这个组合才成为正式约束。

fixture 必须使用虚构 token 和设备 ID，不得保存真实 token、IMEI 或学生信息。

## 9. 全量迁移

### 9.1 盘点

扫描以下模式并逐项人工分类，不能仅凭变量名批量修改：

- adapter / probe 对 response header、body、URL 的 regex、JSONPath 或字符串切片；
- `token`、`session`、`code`、`openid`、`client_id`、cookie、认证 header 候选；
- 从一次响应流向后续 URL/header/body/cookie 的值；
- `setEphemeralCookie` 的 value 来源；
- 日志、异常或 envelope 中可能携带的中间值。

普通业务解析正则不迁移；只有人工确认的 credential-equivalent、opaque flow value 或敏感回显进入 Masker。

### 9.2 分阶段 PR

1. 接受 ADR-026，锁定 schema 与失败语义。
2. 增加 schema、validator、共享 golden 和 policy diff，不接生产路径。
3. 实现 Dart/TS Capture / Project 纯函数，人工安全复核。
4. 抽出统一 delivery firewall，证明 declarative / imperative 无旁路。
5. 接通 execution-local handle 和 Credential Store 事务。
6. 以空调 fake fixture 做小型 credential capture + named-header injection 验证。
7. 逐 adapter 迁移正则/JSON 凭证提取和后续手工注入。
8. 全量 replay、人工签收和旧 bundle 吊销。
9. 启用发布门，拒绝未解释的 adapter-side credential extraction 新增。

这是一个大重构，但每个 PR 保持单一目的。旧路径只在迁移分支短期存在，不新增长期 backward compatibility 开关。

## 10. 审查与发布门

每个 observation 至少记录：

- synthetic id 和脱敏 evidence fixture；
- `credential-equivalent | opaque-flow | sensitive-redact` 分类；
- 可重放、鉴权、会话延续或敏感性的人工理由；
- Masker rule id；
- destination 与后续注入点；
- reviewer、日期和关联 adapter version。

CI / release tooling 必须检查：

- observation -> rule -> destination -> replay 引用闭合；
- raw fixture 中 synthetic canary 在 delivered fixture 中不存在；
- adapter golden 在投影响应上通过；
- adapter 代码不再读取该字段；
- 规则删除、scope 放宽、credential 生命周期改变相对上一 official policy 显式报错；
- request/network/credential/bind 变化触发安全复审；
- bundle digest 覆盖 `masker.json`；
- 旧泄漏版本进入 revocation / `minVersion`；
- review fixtures 和 observations 不进入 bundle。

签名台账建议增加 `maskerDigest` 或等价 policy 摘要、policy baseline version 和安全复核引用，便于确认签名者实际审阅的策略版本。

## 11. 测试矩阵

### 11.1 纯函数与跨端 golden

- adapter/capability/method/final URL 匹配；
- header 大小写、JSON 顶层/嵌套/数组下标/转义；
- 零次、一次、多次命中；
- 类型、单值、总预算和 body 上限；
- 固定 sentinel、幂等执行和实体头清理；
- 多规则全成功才提交；
- Dart/TS 逐例同结果、同错误分类。

### 11.2 Broker 到 adapter

- raw canary 不进入 declarative responses；
- imperative `ctx.fetch` 只读取投影后的 headers/body；
- opaque handle 可在核心中注入，但 adapter 不见源值；
- credential capture 成功后只在批准 scope 注入；
- capture 成功而 project/commit 失败时不交付、不发送下游请求；
- redirect 按 final URL 重新匹配和校验；
- canary 不进入日志、异常、trace、cache 或 envelope；
- 生产 API 不存在绕过 delivery firewall 的 marshal 路径。

### 11.3 签名和版本

- 未验签、schema 非法、scope 越界和 host 版本不足均拒载；
- adapter 代码与 policy 不可拆分更新；
- policy 删除和放宽触发人工 waiver；
- 旧漏洞 bundle 不可从 catalog、缓存或 baseline 回退；
- review 材料不进入发布包。

## 12. 人工签收要求

ADR-026 触碰凭证、Broker、契约和签名承重路径。实现和测试必须人工主导，并至少包含：

- 一名 owner 对 schema 和失败语义签收；
- 一名人工 reviewer 对统一 delivery firewall 无旁路签收；
- Credential Store 与 opaque handle 生命周期复核；
- Dart/TS golden 和 raw-to-adapter replay；
- 首批 adapter 逐个迁移清单；
- 无真实学生数据和真实凭证确认；
- 发布、吊销和回退演练。
