# Response Masker 工程说明

> **状态：仅供讨论，暂不实施。** 本文是 [`ADR-026`](../adr/adr_026_response_masker.md) 的工程化展开；ADR-026 当前为延后（Deferred），因此本文不授权修改 Broker、契约、签名 bundle 或 adapter。恢复议题时须先完成人工安全评审并接受 ADR。

## 1. 目标与边界

Response Masker 是 Broker 向 adapter 交付响应前的一层纵深防御。它用于处理人工审核已确认的校本特殊凭证载体，例如：

- 某个学校把会话值放进 `ETag` 等通常允许交付的响应头；
- JSON body 的固定字段具有鉴权、重放或会话延续效果；
- HTML 属性、文本节点或内联脚本片段包含凭证等价物；
- 已知文本响应中的固定片段需要在交给 adapter 前替换。

本方案不尝试从任意响应中自动判断什么是凭证，也不以词表扫描替代人工审核。fixture 是发现与回归证据，`masker.json` 是运行时规则；两者职责必须分开。

本方案遵守以下边界：

- 凭证值和等价物仍只由可信核心处理（红线 #1）。
- Masker 不给 adapter 增加网络、凭证、存储或副作用能力（红线 #5）。
- `masker.json` 属于签名 bundle 的新增稳定格式，落地前必须由 ADR 接受并按契约流程治理（红线 #6）。
- Masker 不替代 `Set-Cookie` 隔离、响应头 allowlist、重定向隐藏、query 收割和 dataflow 回显剥离。
- 人工审核仍是“字段是否为凭证等价物”的信任锚；Masker 只固化已确认结论。

## 2. 安全定位

Masker 是 best-effort 的最后一道防线，不是完备凭证识别器。已确定的失败策略是“记录并继续”：规则目标缺失、解析失败或匹配数量异常时，不阻断 capability。因此它可以降低已知泄漏再次发生的概率，但不能证明未知或格式漂移后的凭证不会进入 adapter。

以下情况仍须依赖人工审核：

- adapter 与 fixture 同时漏掉某个凭证字段；
- 学校改用尚未登记的新字段或新编码；
- 凭证被拆分、计算或放进无法静态定位的结构；
- official 签署者错误批准了缺少规则的 bundle；
- Masker 解析失败后按既定策略继续交付原响应。

Masker 的日志不得包含原始值、命中片段、body、带 query 的 URL 或可推导凭证长度的信息。

## 3. 统一交付顺序

declarative 与 imperative 响应必须经过同一条 Broker delivery firewall：

```text
Transport 原始响应
  -> Cookie / redirect / query 等核心处理
  -> declarative bind 脱敏前抽取
  -> 通用响应头 allowlist
  -> Response Masker
  -> dataflow 注入值回显剥离（适用时）
  -> adapter
```

接入约束：

- Masker 在重定向终点确定之后按 final URL 匹配。
- `Set-Cookie` 捕获、凭证收割和核心 `bind` 必须先于 Masker，保证核心仍可使用原值。
- 任何 marshal 进 QuickJS 的网络响应必须经过 delivery firewall。
- Masker 不能设计成调用方可省略的 nullable callback。
- 测试 helper 若需要绕过，必须是 testing-only API，生产构建不可调用。
- 多条规则同时命中时取并集；不存在“窄规则覆盖或取消宽规则”。

当前预期接入 seam：

- Dart：`client/lib/core/broker/fetch_proxy.dart` 的响应交付段；
- declarative：`client/lib/core/declarative_host.dart` 在写入 `responses[key]` 之前；
- imperative：`client/lib/core/adapter_runtime.dart` marshal `ctx.fetch` 结果之前；
- TS：`server/src/runtime/broker/fetch-proxy.ts` 的对称交付段。

落地时应先抽出统一且不可绕过的 delivery API，避免四处分别调用 Masker。

## 4. 签名配置

每个 adapter 可带一个独立的 `masker.json`：

```text
school-foo/
  manifest.json
  masker.json
  index.js
  fixtures/
    raw/
    delivered/
    security-observations.json
```

运行时配置要求：

- `masker.json` 进入 adapter bundle 的 digest 与 official 签名覆盖范围；
- 验签成功后才允许解析和使用规则；
- `adapterId` / school 身份只取已验签的 `manifest.json`，规则不得另行自报身份；
- 非法 schema、越界 URL scope 或超限规则导致整个 adapter 拒载；
- 规则默认 append-only，删除历史规则必须有显式安全复核记录；
- catalog 原子指向 adapter bundle digest，避免新规则与旧代码错配；
- 已确认泄漏的旧版本通过 revocation / `minVersion` 禁止回退；
- fixtures、审核记录和真实抓包不进入发布 bundle。

选择随 adapter 签名意味着：签名后的 adapter 不能单独删除规则，但提交者仍可能同时漏写代码审查结论和规则。人工签名门必须检查 `security-observations.json`、`masker.json` 和端到端测试是否闭合。

## 5. 规则草图

以下仅用于约束工程讨论，不是已接受契约：

```json
{
  "schemaVersion": 1,
  "rules": [
    {
      "id": "jw-grades-etag-session",
      "match": {
        "capability": "grades.list",
        "method": "GET",
        "urlScope": "https://jw.example.edu/api/grades*"
      },
      "targets": [
        { "source": "header", "name": "etag" }
      ]
    },
    {
      "id": "jw-grades-body-session",
      "match": {
        "capability": "grades.list",
        "method": "GET",
        "urlScope": "https://jw.example.edu/api/grades*"
      },
      "targets": [
        { "source": "json", "path": "$.session.token" }
      ]
    }
  ]
}
```

规则匹配上下文：

- `adapterId`：来自已验签 manifest，不由规则填写；
- `capability`：必需；
- `method`：可选，大小写规范化；
- `urlScope`：必需，复用 `network.allow` 的 URI scope 语义；
- final URL：运行时匹配权威；
- declarative request key：可选附加条件，不可作为两种 requestGraph 的共同主键。

静态 validator 应强制 `urlScope` 是 adapter `network.allow` 的子集，并对规则数、selector 长度、嵌套深度和总文件大小设上限。

## 6. Selector 与掩码动作

首期预期覆盖多种响应格式，但每类只提供封闭能力面：

| 来源 | Selector | 动作 |
|---|---|---|
| header | 大小写不敏感头名 | 删除整个头 |
| JSON | 受限 JSONPath | 标量替换为核心固定 sentinel |
| HTML | CSS selector + `text` 或固定 attribute | 目标值替换为固定 sentinel |
| text / script | 安全正则 + capture group | 仅替换指定 capture span |

固定 sentinel 建议为 `__ELECON_MASKED__`。规则不得提供自定义 replacement，避免配置成为内容生成语言。

约束建议：

- JSONPath 复用 ADR-023 的受限语法，不开放递归、filter 或 wildcard；
- JSON 只允许命中字符串、数字、布尔和 `null` 等标量，不允许整体替换对象或数组；
- HTML selector 不执行脚本，只能替换文本或显式属性；
- 文本规则复用线性安全正则子集，禁止 lookbehind、反向引用和高风险回溯结构；
- capture 必须返回明确字符区间，Dart/TS 对 Unicode offset 语义保持一致；
- body 发生改变后，删除不再可信的 `Content-Length`、`ETag` 等实体元数据；
- 规则执行须幂等，多次执行不得继续改变结果。

是否复用现有 HTML stdlib、如何保证 Dart/TS HTML 序列化逐字节一致，留待 ADR 恢复时以 probe 验证；不得在 Deferred 状态下先引入依赖。

## 7. 失败与日志语义

按当前议题结论，Masker 不因规则运行失败而阻断 capability：

| 情况 | 行为 | 安全事件 |
|---|---|---|
| selector 未命中 | 原响应继续交付 | `target_missing` |
| JSON / HTML 解析失败 | 原响应继续交付 | `parse_failed` |
| 正则 group 不存在 | 原响应继续交付 | `capture_missing` |
| 命中次数与预期不同 | 尽可能全部替换后继续 | `unexpected_count` |
| Masker 内部异常 | 捕获，原响应继续交付 | `masker_internal` |

安全事件只允许记录：

- `adapterId`；
- capability；
- `ruleId`；
- 枚举化失败原因；
- 已脱敏的 endpoint 标签。

本失败策略优先可用性。若未来要求 Masker 成为红线 #1 的强保证，必须另行修订 ADR，将关键规则改为 fail-closed 或禁止原 body 进入 adapter。

## 8. Fixture 与人工审核

fixture 只保存脱敏后的合成数据。发现真实凭证字段后的流程：

1. 使用测试账号和隔离环境确认字段确有鉴权、重放或会话延续效果。
2. 删除真实响应值和学生数据，替换成明显的 synthetic canary，同时保留必要结构。
3. 在 `security-observations.json` 记录结论、证据 fixture、规则 ID、原因、日期和审核人。
4. 人工添加对应 `masker.json` 规则。
5. CI 检查 observation、规则和测试引用闭合。
6. raw replay 从 Transport 响应开始，经 Broker 与 Masker 后交给 adapter。
7. delivered fixture 验证固定 sentinel 不破坏 adapter 归一化。

审核记录草图：

```json
{
  "observations": [
    {
      "id": "jw-grades-body-session",
      "evidence": "raw/grades-list.json",
      "classification": "credential-equivalent",
      "reason": "该字段可作为后续请求的 session 参数",
      "reviewedAt": "2026-07-27",
      "reviewers": ["reviewer-id"]
    }
  ]
}
```

CI 只能保证已登记 observation 没有失去对应规则，不能发现 observation 自身的遗漏。

## 9. 与跨请求数据流的兼容

如果被掩码字段当前由 imperative adapter 读取并用于后续请求，直接启用 Masker 会打断流程：

```text
响应 body token -> adapter 读取 -> adapter 拼入下一请求
```

启用规则前，应优先迁移为 ADR-023 的核心内数据流：

```text
Broker 脱敏前 bind -> 不透明句柄 -> Broker 注入下一请求 -> adapter 只看到掩码响应
```

每条 body 规则进入 official bundle 前必须检查：

- adapter 是否读取该字段；
- 字段是否参与后续分支、签名或请求参数；
- 字段是否进入 `setEphemeralCookie`；
- declarative dataflow 是否已有足够 extractor / compute / inject 能力；
- 掩码后旧 adapter 是否仍通过 fixture golden。

无法迁移且确实需要 adapter 读取的值，不得仅为追求规则覆盖而强行掩码；该冲突须回到人工安全评审。

## 10. 测试矩阵

### 10.1 Broker 纯函数

- school / capability / method / final URL 命中与不命中；
- 多规则并集、重复规则幂等；
- header 大小写；
- JSON 顶层、嵌套、数组下标、转义和非法 JSON；
- HTML 文本与属性；
- 正则零次、一次、多次、非法 pattern 和 Unicode；
- body 修改后的实体头清理；
- Dart / TS 共用 `contract/golden/broker/response-masker.json` 双跑。

### 10.2 Broker 到 adapter

- raw Transport response 经完整 declarative host 后，canary 不进入 adapter；
- imperative `ctx.fetch` 只能读取掩码后的 headers/body；
- 核心 `bind` 可在 Masker 前读取原值；
- dataflow 回显剥离仍在 Masker 后生效；
- redirect 按 final URL 规则匹配；
- CookieJar、query harvest 和 credential store 不受 Masker 改写；
- canary 不进入 envelope、日志、异常、trace 或缓存。

### 10.3 签名与发布

- `masker.json` 被 bundle digest 覆盖；
- 文件篡改、未知 schema、越界 scope 和资源超限均拒载；
- catalog / bundle 原子更新；
- 旧泄漏版本不可回退；
- fixtures 和审核记录不进入 bundle；
- 删除历史规则触发显式安全复核闸门。

## 11. 未来实施顺序

ADR-026 恢复并经人工接受后，建议按以下小 PR 推进：

1. 契约：新增 `response-masker.schema.json`、validator 和共享 golden。
2. 签名：将可选 `masker.json` 纳入 bundle digest、加载校验和发布检查。
3. 纯执行器：实现 Dart / TS 对称的 header、JSON、HTML、text Masker。
4. 交付 seam：建立不可绕过的 Broker delivery firewall。
5. Replay：补 raw Transport 到 declarative / imperative adapter 的端到端夹具。
6. 审核闭环：增加 `security-observations.json` 与 observation -> rule -> test 检查。
7. 试点：各选一个 synthetic ETag 和 body credential 场景，完成人工安全清单。

上述实现触碰红线 #1、#6 及签名承重路径，须人工主导、至少一名人工审阅并附安全检查清单；AI 不得独自闭环。
