# ADR-011：Capability 业务响应缓存与生命周期

- **状态**：已接受（Accepted）
- **日期**：2026-08-14
- **依赖**：[ADR-000](./adr_000_abstract.md)、[ADR-003](./adr_003_core_security_boundary.md)、[ADR-004](./adr_004_credential_store.md)、[ADR-005](./adr_005_adapter_v2.md)、[ADR-010](./adr_010_signer_identity.md)

## 1. 背景

当前客户端没有 capability 业务响应的持久化缓存；业务结果只在一次 invocation 和内存中的 `CampusSnapshot` 中存在。后续需要支持离线展示、减少重复请求和 stale-while-revalidate，但成绩、课表、余额、交易、借阅等结果属于用户设备侧的私密数据。

仅使用：

```text
profileId / adapterId / capabilityId / schemaId / works.title
```

不能唯一标识一个结果，也不能构成安全边界。`adapterId` 不区分 bundle digest、signer 或 trust epoch；`schemaId` 当前实际由 `schema` 与 `schemaVersion` 组成；`works.title` 是 payload 字段，不是响应身份；请求参数、数据源和凭证会话也会影响结果。

## 2. 决策

### 2.1 缓存对象

第一阶段只缓存完整的、通过宿主 exact schema/version 校验的 capability 输出。缓存入口只接受 ADR-003 §13 定义的 `ValidatedCapabilityOutput`，不得缓存部分解析结果、原始 HTTP response、凭证、cookie、adapter 中间状态或未验证的动态对象。

字段级缓存（例如 `works.title`）不作为第一阶段能力。payload 内的字段路径属于数据内容；如未来确有字段级缓存需求，必须另行定义一致性和失效规则。

### 2.2 逻辑身份

缓存命中身份至少包含以下维度：

```text
profileId
dataSourceId
producerAdapterId
producerBundleDigest
trustEpoch
capabilityId
outputSchema
outputSchemaVersion
canonicalParamsHash
credentialSessionGeneration（仅当结果依赖凭证会话时）
```

其中：

- `profileId` 由宿主 invocation context 注入，adapter 不得传入或选择；
- `dataSourceId` 区分同一 profile 中不同校园系统；MVP 中可与 profile 的学校绑定，但不得因此取消字段语义；
- `producerBundleDigest` 是精确执行内容身份，不能用 `adapterId` 或 adapterVersion 代替；
- `trustEpoch` 使 revoke、disable、delete 或重新信任后的旧执行面不能继续命中；
- `outputSchema` 与 `outputSchemaVersion` 必须使用 manifest 实际验证的精确值；
- `canonicalParamsHash` 是参数 canonical JSON 的哈希，参数字段顺序不影响结果，参数值变化必须改变身份；
- `credentialSessionGeneration` 用于成绩、余额、交易、个人信息、借阅等依赖登录会话的 capability，重新登录、登出或会话替换后旧结果默认失效。

逻辑 key 使用结构化记录表示，不在 API 中接受任意拼接字符串。物理文件名或索引使用整个 canonical key 的哈希，禁止将 profile、学校、adapter、capability、参数或 payload 字段直接写入可观察路径、日志或明文索引。

### 2.3 访问控制与 owner

缓存由宿主拥有并由 invocation context 授权访问。adapter 只能访问当前 profile、当前 active adapter identity 和当前 capability 允许的缓存；adapter 不能通过伪造 key 访问其他 profile、其他 trust epoch 或其他 bundle digest。

默认情况下，缓存是 producer adapter 的私有结果。跨 adapter 共享不是默认行为；如未来需要共享，必须像 Credential Store 一样对同一 profile 内的 exact source namespace、target adapter 和 `read`、`write`、`delete` 分别声明并由宿主逐操作强制。知道缓存 key 不构成访问授权。

缓存不替代 Credential Store。Credential Store 继续只负责凭证和其生命周期；业务响应缓存使用独立的加密存储、索引和清理流程。

### 2.4 新鲜度与失效

每个 entry 至少保存加密 envelope 内的：

```text
createdAt
freshUntil
staleUntil
schema identity
producer identity
credential dependency
source revision（若可用）
cache format version
encryption key version
```

必须区分 fresh、stale 可离线展示和不可用三种状态。缓存策略由宿主决定，不能把旧响应伪装成在线新结果。使用 `now`、时间段、学期、分页、日期或其他动态上下文的 capability 必须将其实际输入纳入参数身份，或由明确策略禁止长期缓存。

以下事件至少导致相应缓存不可命中或清除：

- profile lock/logout：按数据敏感度阻止读取；依赖旧 Credential grant 的结果立即不可用；
- profile delete：删除该 profile 的全部密文、索引、临时文件和内存副本；
- adapter disable/revoke/delete：禁止旧 digest/epoch 结果交付；
- ADR-010 identity conflict replacement：不得继承冲突 adapterId 的旧结果；
- adapter uninstall：缓存必须与 self namespace 的保留/清空选择分别定义，不能默认继续暴露旧业务数据；
- schema 不兼容升级：旧结果不得被新 validator 或 UI 直接当作新 schema 使用；
- credential session generation 变化：依赖旧会话的结果不可命中。

### 2.5 存储保护

缓存正文、索引和可推断使用情况的元数据必须位于 profile 绑定的认证加密边界内，排除普通备份、云同步、遥测和 crash report。写入必须原子完成；取消、超时、grant/epoch 变化、schema 校验失败或加密/落盘失败不得留下可交付的半条目。

缓存清理必须覆盖正文、索引、临时文件和进程内副本。日志不得记录完整 key、canonical 参数、响应正文或可恢复的 profile/adapter 关联。

## 3. 实施顺序

本 ADR 不授权在 legacy loader 或现有全局 `ref` Credential Store 上直接叠加业务缓存。实现必须先完成以下基础设施门：

1. ADR-005 的 Manifest V2、精确 bundle digest、active binding 和 trust epoch；
2. ADR-004 的宿主绑定 profile、adapter namespace、锁定/删除生命周期和认证加密存储；
3. ADR-003 的 validated output、params schema 校验、invocation cancel/epoch 检查和原子提交屏障；
4. 独立的 cache API、加密 envelope、canonical key/hash、TTL/stale 语义和清理任务；
5. 负例测试覆盖 profile、digest、epoch、参数、schema、凭证会话和跨 adapter 访问。

在第 1 至第 3 项未达到 required gate 前，客户端可以继续使用内存结果，但不得将业务响应持久化为“缓存已支持”。

## 4. 必测负例

- 相同 `adapterId`、不同 bundle digest 不命中同一结果；
- revoke 或 trust epoch 变化后旧结果不可交付；
- profile A 的缓存不能被 profile B 读取；
- 不同 canonical params、dataSourceId、schema/version 或 credential generation 不串缓存；
- 未声明的跨 adapter cache read/write/delete fail closed；
- schema failure、取消、超时和落盘中断不产生可交付半条目；
- profile lock/logout/delete、adapter uninstall/revoke/delete 的缓存行为符合本 ADR；
- 缓存正文、索引、key path 和参数不进入日志、备份、遥测或 crash report；
- stale 数据在 UI 中明确标示，不伪装为 fresh 在线响应。

## 5. 代价与后续

该决策增加了 cache key canonicalization、加密索引、生命周期清理和测试成本，也会降低不同 adapter 版本之间的缓存复用率。代价换取的是 profile、执行身份、schema 和认证会话之间的明确边界。

后续如要把缓存 key、TTL/freshness、共享权限或 envelope 纳入 `contract/`，必须以本 ADR 为前置，并保持向后兼容；破坏性 schema 变化需要单独版本和迁移说明。
