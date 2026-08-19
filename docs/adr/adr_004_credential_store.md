# ADR-004：Credential Store 与私密数据边界

- **状态**：已接受（Accepted）
- **日期**：2026-08-11
- **依赖**：[ADR-002](./adr_002_execution_trust.md)、[ADR-003](./adr_003_core_security_boundary.md)
- **相关决策**：[ADR-011](./adr_011_capability_response_cache.md)；本 ADR 不定义学校业务响应缓存

## 1. 决策

`profile` 只表示“一个用户在一所学校中的完整登录身份域”。另一个用户、同一用户以另一身份登录或切换到另一学校都必须使用另一个 profile。adapter 永远不能指定、枚举、读取、写入、删除或通过跨 namespace 声明触达其他 profile。

MVP 只支持单用户、单学校，首次启动由宿主创建并持久化唯一 `profileId`，不提供 profile 创建或切换 UI。即使 MVP 只有一个 profile，所有 Credential Store、runtime、后台任务和 transaction 仍必须绑定该宿主签发的 ID，不得先落一个无 profile 的全局契约。MVP 中 school 等同 profile，不在 credential key 内重复保存 `schoolId`。

每个 profile 内，Credential Store 以稳定 `adapterId` 建立 owner namespace。所有受信 adapter 默认只能通过统一 JS API 枚举、读取、写入、更新和删除自己的 namespace；adapter 自身不能传入任意 `profileId`，宿主从 invocation context 注入当前 profile。

namespace 内的 MVP canonical key 为：

`profileId / adapterId / systemId / credentialName`

一个学校可以有多个独立校园系统，使用 `systemId` 区分。profile 已代表唯一用户身份，MVP 不再重复 `schoolId` 或 `accountId`。不得只以全局裸字符串 `session`、`token` 寻址。

`systemId` 和 `credentialName` 均为 adapter 定义的 canonical lowercase slug，限制为 ASCII 字母、数字、点和短横线，禁止空值、路径分隔符、Unicode、大小写别名和非 canonical form。`systemId` 例如 `cas`、`dean`、`library`；发布后改名视为显式凭证迁移，不自动查找或合并旧分区。

跨 adapter namespace 访问只能发生在同一 profile 内，并且必须在 Manifest V2 中对 exact target `adapterId` 分别声明 `read`、`write`、`delete`；`list` 归入 `read`。声明是宿主强制上限，未声明 namespace、未声明操作、动态 wildcard 或任何跨 profile 访问均 fail closed。manifest 不存在申请跨 profile 权限的字段。

非 official adapter 的整体安装/加载风险页必须显著展示全部跨 namespace 目标和访问模式，但不增加独立权限弹窗；用户确认 exact bundle digest 时整体接受这些声明。official adapter 的声明经过审核后静默加载，不向用户弹窗，但 official 不得绕过 namespace enforcement 或访问未声明范围。

复合键防止同一学校不同系统和 credential 串号；profile boundary 隔离完整用户身份；namespace enforcement 阻止未声明的跨 adapter 枚举、读取、覆盖和删除。adapter 仍可泄漏或破坏自身 namespace 及同 profile 内获准跨域范围中的数据。

## 2. API 与一致性

Credential value 使用 typed record，至少包含：

- `kind`；
- 有界 JSON-compatible opaque secret payload；
- 可选 expiry；
- 有界 metadata。

标准 kind 至少包括 `cookie`、`token`、`password`；adapter 可以使用 canonical 反向域名 custom kind。payload 支持严格 JSON-compatible value 和 `Uint8Array`，由宿主使用版本化 tagged encoding 保存二进制；不接受任意 class instance、function、symbol、Map、Set、循环引用、NaN 或 Infinity。宿主只校验 envelope、预算和值域并负责加密存储，不解释 cookie、token 或 custom payload 的业务结构。该开放 payload 保留爬虫式开发自由，不建立封闭凭证 DSL。

expiry 使用宿主统一时间语义计算。到期 record 不自动删除；`get/list` 返回明确 `expired` 状态，由 adapter 决定 refresh 或 delete。logout、profile 删除等显式生命周期操作仍可强制物理清除。

MVP 写入采用 last-write-wins，不提供 compare-and-set 或 version 冲突错误。ADR-003 的 invocation overlay 仍保证单次 capability 的 staged writes 成功后原子提交；不同 invocation 对同一 key 的最终值由提交顺序决定。宿主不保证旧 refresh 不会覆盖较新值，该竞态是明确接受的 MVP 代价。

`list` 一次只能指定一个 namespace 和一个 `systemId`。self namespace 可隐式定位；跨 namespace 必须指定 manifest 已声明 `read` 的 exact target。API 不提供跨 namespace、跨 system 或全 profile 聚合枚举。`read` 授予完整 record 可见性，`get/list` 均可返回 kind、payload、expiry、expired 和 metadata；`list` 不是仅名称或 metadata 枚举。非 official 风险页必须把跨 namespace `read` 描述为可批量读取该 system 中的秘密。

单 record 的 tagged encoding 在加密前最多 1 MiB；单 profile 的全部 namespace 合计最多 64 MiB。上限是全平台 contract，写入必须在加密和持久化前预留并检查，超限稳定失败。Credential Store 不是学校响应缓存或任意私密数据库。

### 2.1 生命周期

- **普通卸载 adapter**：用户必须选择保留或永久清空当前 profile 下该 `adapterId` 的 self namespace。保留时须警告后续同 ID 安装，尤其 unsigned bundle，可以接管这些凭证。该操作不删除 adapter 曾跨域写入的其他 owner namespace。
- **ADR-010 identity 冲突强制替换**：不提供保留选项，必须清空当前 profile 下冲突 `adapterId` 的完整 namespace。
- **profile logout**：停止该 profile 的所有 adapter runtime 和任务，将 profile 标记 locked，但保留加密凭证。locked profile 不铸造 Credential grant，所有 store API 稳定失败为 `PROFILE_LOCKED`。
- **profile unlock**：只能由宿主 UI 经用户显式操作完成；adapter 不能读取、写入或切换 lock state。设备认证还是学校重新登录由后继 UI/WebView ADR 裁定。
- **profile delete**：不可恢复地删除该 profile 的全部 namespace、安装选择、trust/任务关联和密钥材料。MVP 虽不提供多 profile UI，仍须提供“清除学校身份”的 profile delete 操作。
- **应用卸载**：由平台安全存储和数据目录清理覆盖全部 profile；不得依赖普通备份恢复 trust 或凭证。

### 2.2 存储保护

每个 profile 使用独立随机主密钥，由平台 Keychain、Keystore 或等价安全存储包装。adapter、namespace 和 JS runtime 永远拿不到主密钥。所有 record 必须使用认证加密；除存储格式版本、算法参数、随机 nonce 和必要密文 framing 外，以下信息不得明文落盘：

- profile 映射；
- `adapterId / systemId / credentialName` key path；
- kind、expiry、metadata 和 payload；
- namespace/system 索引和 record 数量等可推断学校使用情况的信息。

查询索引也必须位于认证加密边界内，不能通过旁路明文文件重新泄漏 key path。精确 AEAD、key wrapping、nonce、崩溃恢复和轮换格式须在实现前由安全评审固定；硬件保护不可用时不得静默谎报或降级到普通存储。

用户首次显式解锁 profile 后，宿主可以在进程内缓存已解封的 profile 主密钥，使普通设备锁屏期间的后台任务继续访问。profile logout/lock/delete 时必须先停止 runtime 和任务、失效 grant，再尽力 zeroize 进程内密钥；进程结束时缓存自然失效。仅持有缓存密钥不能绕过 profile lock 或 grant epoch。

Credential 密文、加密索引、profile 主密钥和 lock state 全部排除普通系统备份、设备迁移和云同步。新设备必须重新创建 profile 并登录。未来端到端多设备同步须另立 ADR。

### 2.3 V1 迁移

V2 不把 V1 裸 ref 或旧复合键迁入新 store，也不提供 legacy read-only resolver。首次启动检测到 V1 Credential Store 时，必须先阻止 V1/V2 adapter runtime 和后台任务启动，再以可恢复迁移标记清空旧凭证，创建新的唯一 profile，并要求用户重新登录。

不得根据 ref 名、学校配置或当前 adapter 猜测 `adapterId/systemId/credentialName` owner。崩溃恢复必须最终收敛到“旧库不可访问且新 profile 明确为空”，不能出现新旧库同时可读或把旧凭证暴露给同名 unsigned adapter。

后继 contract 仍须固定：

- `list/get/put/delete` 的 typed value；
- 宿主隐式绑定的当前 profile、self namespace 的隐式寻址与同 profile 跨 namespace 的显式 target；
- manifest `read/write/delete` 声明、grant 绑定与逐操作检查；
- invocation overlay 的原子提交和 last-write-wins 顺序；
- 过期时间、session 与长期材料；
- logout、profile 删除、adapter 删除和应用卸载的数据生命周期；
- 执行取消后不得提交 staged write。

平台后端继续使用 Keychain、Keystore 等安全存储包装 profile key；大容量密文可存于排除备份的应用私有目录，但不能因此明文落盘或降低认证加密要求。

## 3. 私密数据路径

真实凭证和学生数据只允许存在于客户端 Credential Store 或用户设备直接发往学校的请求中；系统 VPN 与 official transport/app-tunnel 只承载用户侧链路，不产生项目服务端存储。public 服务、catalog、telemetry、crash report、LLM 审核和 official fixture 均不得接触真实值。

测试只使用合成凭证或脱敏 fixture。V2 不再依赖 opaque handle、自动注入或 mandatory Masker 兑现该边界。

## 4. 必测负例

- MVP 唯一 profile 仍进入所有 key、runtime、任务和 transaction context。
- adapter 无法传入或枚举 profile；构造跨 profile target 必须在 store 前拒绝。
- 同一 profile 内多个 `systemId` 和 `credentialName` 不串号。
- 非 canonical system/credential slug、超预算 payload 和非 JSON value 拒绝。
- adapter 默认看不到其他 namespace；未声明 target 和越权 mode 均拒绝。
- list 必须绑定一个 namespace/system，不能聚合枚举；拥有 read 时返回完整 record。
- 非 official 风险页完整展示跨域声明；official 静默但运行时执行同一上限。
- ADR-010 identity 冲突的普通覆盖不触碰旧 namespace；破坏性确认后清空当前 profile 下该 ID，且不得影响其他 profile。
- 并发 write 按实际 commit 顺序 last-write-wins，并由测试固定，不承诺旧 refresh 保护。
- adapter 卸载保留/清空选项、profile lock/unlock/delete 和 expiry 行为跨平台一致。
- locked profile 不创建 runtime Credential grant，adapter 无法自行解锁。
- 每 profile 密钥隔离；删除一个 profile 的密钥和数据不得影响其他 profile。
- key path、kind、expiry、metadata、payload 和索引均无明文落盘旁路。
- 设备锁屏后已解锁进程可继续后台访问；profile lock/logout 后缓存密钥和旧 grant 不可继续使用。
- backup/restore 和设备迁移不传播 profile key、密文、索引或 lock state。
- 1 MiB record 和 64 MiB profile 上限在加密/写盘前强制，失败不产生部分提交。
- V1 store 清理完成前 runtime/任务不可启动；崩溃重试后旧凭证不可读且新 profile 为空。
- adapter 日志、异常、fixture 和崩溃信息不被宿主自动记录原始值。
