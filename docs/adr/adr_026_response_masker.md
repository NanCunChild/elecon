# ADR-026：校本响应凭证 Masker

- **状态**：延后（Deferred）。本议题将在未来一段时间内保持暂缓；本文只记录问题边界、候选方向和恢复条件，**不构成已接受决策，不授权修改 Broker、契约或签名 bundle**。
- **日期**：2026-07-27
- **适用范围**：Broker 向 declarative / imperative adapter 交付响应前，对人工确认的校本特殊凭证载体执行定向掩码。
- **依赖**：[`ADR-000`](./adr_000_abstract.md)（可信核心与凭证边界）、[`ADR-009`](./adr_009_fetch_credential.md)（响应脱敏与 body 已接受风险）、[`ADR-018`](./adr_018_adapter_distribution.md)（签名 bundle）、[`ADR-023`](./adr_023_declarative_dataflow.md)（不透明句柄与回显剥离）。
- **工程说明**：[`docs/reference/response_masker_plan.md`](../reference/response_masker_plan.md)。

## 1. 背景

现有 Broker 对结构化 HTTP 凭证载体采用强制隔离：`Set-Cookie` 进入核心 CookieJar，响应头按 allowlist 交付，重定向由核心逐跳处理，声明过的 query credential 由核心收割。ADR-009 同时明确接受 response body 原样透传的残余风险，因为 JSON、HTML、脚本和二进制中不存在完备的通用凭证识别算法。

人工审核真实学校接口时，可能获得比通用 Broker 更具体的知识：某个 URL 的 `ETag`、JSON 字段、HTML 属性或文本片段具有鉴权、重放或会话延续效果。若该知识只留在 reviewer 经验、fixture 或测试说明中，运行时仍会把相同字段交给 adapter。

本议题讨论是否把这些人工确认结论固化成一个可配置 Response Masker，在 Broker 向 adapter 交付响应前定向替换已知凭证等价物，作为特殊学校场景的最后一道纵深防御。

## 2. 暂定方向（未接受）

以下是恢复讨论时的当前基线，不是已生效架构：

1. **人工审核是分类信任锚。** 不尝试用词表、熵、字段名或正则自动证明某值是凭证；fixture 仅提供发现与复核证据。
2. **规则放在独立 `masker.json`。** 文件随对应 adapter bundle 一起进入 digest 和 official 签名，不塞进 capability manifest。
3. **Masker 由可信核心执行。** adapter 不能读取 Masker 前的交付响应，也不能在运行时关闭规则。
4. **两种 requestGraph 共用一层。** declarative 和 imperative 必须通过同一个 Broker delivery firewall，不能分别实现可绕过的旁路。
5. **先核心使用、后交付。** Cookie/redirect/query 收割、核心 bind 等动作在 Masker 前完成；adapter 只能看到 Masker 后的响应。
6. **多格式、封闭能力面。** 候选 selector 包括 header 名、受限 JSONPath、HTML selector 和安全正则 capture；不开放任意代码或任意 replacement。
7. **固定替换。** body 命中值替换为核心定义的固定 sentinel；header 目标直接删除。
8. **失败记录并继续。** selector 缺失、解析失败或匹配异常不阻断 capability，只产生不含敏感值的安全事件。
9. **规则取并集。** 多条匹配规则只能增加掩码，不存在覆盖或取消。
10. **配置与代码原子签名。** catalog 指向完整 bundle digest；历史规则删除和旧泄漏版本回退须有显式治理。

## 3. 候选数据流

```text
adapter request declaration / ctx.fetch
  -> Broker 注入决策与 Transport
  -> Cookie / redirect / query 等核心处理
  -> declarative bind 脱敏前抽取
  -> 通用响应头 allowlist
  -> Response Masker（按已验签 adapter 身份 + capability + final URL）
  -> dataflow 回显剥离（适用时）
  -> adapter
```

Masker 不应进入 Transport 层，因为核心仍需在掩码前读取 `Set-Cookie`、redirect、bind 和其他受控值；也不应只放在 adapter runtime 桥接层，否则 declarative 与 imperative 容易产生语义漂移或旁路。

## 4. 为什么不只用词表

词表和 token pattern 无法提供完备保证：

- 学校可使用任意字段名和随机值；
- 凭证可能被 URL、Base64、hex、HTML entity 或自定义算法编码；
- 普通业务 ID 与随机 token 在内容上不可判别；
- 值可能分片、拼接或嵌入脚本；
- 允许响应头也可能被服务端复用为凭证载体。

pattern scanner 仍可用于 fixture、最终 envelope 和日志的审计，但只能告警，不能成为红线 #1 的唯一安全边界。

## 5. 为什么不只依靠 adapter 自报

adapter 声明适合描述它需要的 capability，不适合独自裁定什么是秘密。恶意或有缺陷的 adapter 可以同时漏掉字段识别与掩码声明。

当前候选方案仍选择让 `masker.json` 随 adapter 签名，理由是：

- 规则与 adapter 解析行为需要原子兼容；
- 学校接口变化时可以随 adapter 热更新，不要求 App 发版；
- official 签名门已经是人工审核结论进入 release 的信任边界；
- 签名覆盖后，运行时 adapter 不能单独删除或篡改规则。

该选择不消除同源遗漏风险。它只把信任锚明确放在 official 人工审核与签名门，而不是 adapter 作者自律。若未来需要抵御“已签名 bundle 仍遗漏规则”，应重新评估独立签名 policy pack 或核心内置策略；本 Deferred ADR 不预先接受该扩面。

## 6. 已知代价与残余风险

### 6.1 “记录并继续”不是强保证

选择 availability-first 的失败行为后，接口格式漂移、parser 失败或 selector 漏配可能让原值继续进入 adapter。因此 Masker 只能称为 best-effort 防线，不能宣称关闭 ADR-009 的 body 风险。

若未来希望 Masker 承担红线 #1 的强保证，必须重新评审并至少选择一种更强语义：关键规则 fail-closed、解析失败丢弃 body，或禁止未投影的认证响应进入 adapter。

### 6.2 可能破坏 adapter 流程

某些 imperative adapter 当前必须读取 body token 才能完成后续请求。Masker 若先隐藏该值，会直接破坏功能。启用规则前应将这类值迁移为 ADR-023 的核心内不透明句柄与静态注入；无法迁移时须由人工评审决定是否接受 adapter 可见的残余风险。

### 6.3 多格式实现成本

JSON、HTML 和文本规则须在 Dart / TS 两端保持 selector、Unicode offset、序列化和失败语义一致。HTML 解析器复用、正则 span、实体头清理和 body 字节稳定性均需 probe 后才能确定，不能仅凭文档假设。

### 6.4 签名与版本治理扩大

`masker.json` 进入 bundle 将修改 bundle 文件集合、schema、validator、catalog 兼容和发布检查，触碰红线 #6 与签名承重路径。旧签名版本可能不含新发现规则，须结合 revocation / `minVersion` 防回退。

### 6.5 人工审核无法证明无遗漏

fixture 只能覆盖已观察路径，测试只能证明 synthetic canary 在给定样本中被掩码。它们不能证明学校所有端点、所有响应分支和未来格式都安全。

## 7. 暂缓理由

本议题当前不进入实现，原因是：

1. 尚无经过脱敏、可重复验证的真实学校 ETag/body credential 试点，无法校准规则表达力。
2. 尚未证明多格式 Masker 在 Dart / TS 间可低成本保持确定性。
3. “记录并继续”保可用性但无法升级安全不变量，收益与复杂度需要真实案例验证。
4. `masker.json` 将同时扩张契约、签名 bundle 和 Broker 交付 seam，不应在缺少需求证据时提前建设。
5. ADR-023 的 opaque handle 和源 body 可见性仍有边界需要先行复核，Masker 不应掩盖该基础问题。

## 8. 恢复条件

同时满足以下条件后，方可把本 ADR 从 Deferred 恢复为 Proposed 并进入人工评审：

1. 至少一个真实学校案例证明 allowlisted header 或 body 固定字段具有学生凭证等价效果。
2. 案例 fixture 已彻底脱敏，只保留 synthetic canary，且不含真实学生数据。
3. 已说明该值是否被 adapter 后续流程使用，以及能否迁移为核心不透明句柄。
4. 完成 JSON、HTML、安全正则在 Dart / TS 的 selector 与序列化 probe。
5. 明确 parser 失败、selector 缺失、多次命中和 body 修改后实体头的最终语义。
6. 明确 `masker.json` 的 schema、bundle digest、版本回退和规则删除治理。
7. 准备 Broker delivery firewall 的不可绕过设计与 declarative / imperative 端到端测试计划。
8. 由人工作出是否继续采用“记录并继续”的风险接受结论。

## 9. 若恢复后的预期落地范围

若本 ADR 未来被接受，预计至少涉及：

- `contract/response-masker.schema.json` 与共享 golden；
- `tools/` validator、scanner / fixture 审核闭环；
- adapter bundle include、digest、签名和加载器；
- Dart / TS 对称 Masker；
- Broker 统一 delivery firewall；
- raw Transport -> Broker -> adapter replay；
- 发布安全清单与旧版本回退治理。

这些实现触碰凭证、Broker、契约和签名承重路径，必须人工主导、至少一名人工审阅并附安全检查清单；AI 不得独自闭环。

## 10. 决策结果

**Deferred：不实现。** 保留问题、候选方向和工程说明，等待真实案例与跨端 probe。ADR 状态改变前，任何 PR 不得引用本文为修改 Broker、`contract/` 或签名 bundle 的授权依据。
