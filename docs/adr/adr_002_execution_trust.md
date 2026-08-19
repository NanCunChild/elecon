# ADR-002：执行信任、official 与本地 digest trust

- **状态**：已接受（Accepted）
- **日期**：2026-08-11
- **依赖**：[ADR-000](./adr_000_abstract.md)、[ADR-001](./adr_001_project_shape.md)
- **后继细化**：[ADR-005](./adr_005_adapter_v2.md)、[ADR-006](./adr_006_official_governance.md)、[ADR-009](./adr_009_ios_appstore.md)

## 1. 背景

V1 客户端只有完整的 official 加载链。现有 `dev-sideload` 是不绑定 digest 的 debug build profile，不是可持久化、可撤销的用户信任；客户端也没有 local install registry、active binding 或 trust store。V2 必须先建立不可伪造的执行 grant，再允许受信 adapter 进入 QuickJS 和宿主 API。

本 ADR 固定“哪些 `.eleb` 字节可以获得哪种执行信任”以及 trust 的生命周期。Manifest V2、`.eleb`、canonical serialization、QuickJS ABI 和 digest 测试向量由 ADR-005 固定；official 签名与独立 revocation 的发布 ceremony 由 ADR-006 固定；第三方 signer 连续性由 ADR-010 固定。

## 2. 总体决策

信任只由宿主裁定。manifest 字段、adapter ID、文件名、目录来源、自报 tier 或已有缓存均不能产生信任。

过渡期有三条生产执行路径：

1. **official**：项目 official 签名、bundle identity、兼容门和独立 official revocation 全部闭合后自动受信；
2. **local**：第三方 signer 签名，用户首次确认 `(profileId, adapterId, signer fingerprint)` 后受信，后续更新按 ADR-010 执行；
3. **local unsigned**：仅 Android 和 desktop 暂时允许用户在完整风险确认后运行无签名 `.eleb`，属于明确待删除的迁移路径。

三条路径进入同一个客户端 QuickJS runtime、Credential Store namespace enforcement 和宿主网络边界。local/local unsigned 不是低权限 runtime 档；所有路径都默认完整控制自己的 `adapterId` namespace，并且只能按 manifest 声明的 `read`、`write`、`delete` 模式跨 namespace 访问。非 official 安装页展示 signer、载荷形态、网络与跨域声明，official 经审核后静默加载，但宿主对三者执行同一强制上限。

有效第三方签名只证明 signer 连续性，不自动等价于 official。首次 local 安装必须确认 signer；首次 unsigned 安装绑定用户确认的 exact digest。已经 active 的 unsigned installation 可按 §6 的同 ID 主动导入规则更新。

当 local signer 工具、首次确认、冲突处理、迁移 UI、contract vectors 和 release artifact gates 全部成为 required checks 后，local unsigned 仅保留一个稳定版本的 deprecated 新装与运行窗口；下一个稳定版本删除全部生产 unsigned grant、导入与执行路径。删除后包括 debug 开发构建在内的所有 adapter 都必须签名；开发者使用隔离的本机或一次性开发 signer，不保留 unsigned bypass。

## 3. Canonical bundle digest

执行信任绑定版本化的 canonical V2 content digest，而不是导入文件的 gzip/JSON 原始字节，也不沿用只组合文件内容哈希的 V1 算法。

该 digest 至少覆盖：

- bundle format 与 digest algorithm ID；
- 规范化后的文件路径；
- 文件 encoding；
- 文件长度与完整文件字节；
- 影响执行内容解释的其他 envelope 字段。

文件顺序、路径规范化、整数和字符串编码必须唯一化并由跨语言测试向量固定。detached signature 不进入 content digest；因此签名增加、替换或移除不改变执行内容 identity。精确 canonical encoding 由 ADR-005 裁定，ADR-005 接受前不得实现新的生产 digest。

trust record 必须同时保存 digest algorithm ID 和 exact digest。未知算法、已废弃算法、digest 不匹配或 canonicalization 失败均 fail closed，不得回退到 V1 digest。

## 4. Official 准入与离线行为

带 signature 的 `.eleb` 必须按其唯一 Ed25519 signer identity 进入 official 或 local 路径。签名无效、多签、identity 不闭合、兼容门失败或 official 命中已知 revocation 时，loader 必须拒绝；不得自动或提示式降级为 unsigned。

在 local unsigned 迁移窗口内，用户可以在应用外使用独立工具显式移除 detached signature，并把结构上无签名的 `.eleb` 作为新的 unsigned import 重新提交。生产客户端不提供签名剥离或重打包功能。重新导入必须从 unsigned 预检和完整风险确认开始，不能继承失败的 signed load context。unsigned 路径删除后，该转换不再产生可执行安装。

official loader 无法联网刷新治理元数据时，可以继续使用已验签、sequence 防回滚的 last-good revocation：

- 已知命中吊销的 digest 继续拒绝；
- freshness TTL 过期必须形成可观测状态，但不立即停止 last-good 中已有 exact digest；
- stale revocation 不降低 `.eleb` 自身的 identity、signature 或兼容门；
- 获取到更高合法 sequence 后不得回滚。

## 5. Local 导入与安装事务

local unsigned 路径只接受结构上无 signature 的 `.eleb`。local signed 与 unsigned 在用户完成首次确认前，都只允许 bounded unpack、canonical digest、manifest/schema、signature/ABI compatibility 校验和对 source 载荷的静态分析；不得创建 adapter runtime、执行 bundle 代码、读取 Credential Store、发起 adapter 网络请求或产生 adapter 持久化副作用。bytecode-only local 必须显著标记客户端无法进行源码级静态检查。

确认界面必须绑定并展示本次实际预检的 exact digest、adapter identity、来源提示、完整网络声明、全部跨 Credential namespace 目标及访问模式和整体信任风险。跨 namespace 展示不产生第二个权限确认；用户对 exact digest 的整体确认同时接受该 manifest 上限。取消、关闭、解析失败或字节变化均不得留下 trust 或 active binding。

安装采用内容寻址和原子提交：

1. 将导入字节写入不可执行的临时区；
2. bounded unpack 并计算 canonical digest；
3. 完成静态校验并展示基于该 digest 的确认；
4. 用户确认后，将 bundle 写入按 digest 寻址的私有存储；
5. 重新读取已安装字节并重算 digest；
6. 原子提交 installation record、trust epoch 和 `adapterId -> active digest` binding。

任一步失败均保留原 active installation，不得产生半可信状态。执行前仍须从私有内容寻址存储读取实际字节并重新校验 digest，禁止执行用户原始导入路径或复用预检后的可替换文件句柄。

每个 `adapterId` 只有一个 active digest。首次安装必须确认 exact digest；用户之后主动导入同 ID unsigned bundle时，bounded preflight 全部通过即可替代并保留 namespace，不对新 digest 再次确认。该规则只表示本机 unsigned installation 连续性，不证明作者相同；首次风险页必须说明任何来源都可制作同 ID unsigned bundle。底层可以暂存旧 digest，但旧 digest 不得与新 digest 同时 active。

## 6. 来源切换与更新

local 与 official 出现相同 `adapterId` 时，宿主不得自动切换来源：

- 当前 active 为 local/local unsigned 时，发现索引出现 official 只产生可见提示；发现索引不是信任根；
- 用户明确切换后才可将 official 设为 active；
- 当前 active 为 official 时，同 ID unsigned 不得普通覆盖；未来按 ADR-010 的破坏性强制替换流程移除旧安装并清空当前 profile 下该 ID namespace 后，才可作为全新 local 安装；
- official 自动更新只适用于当前选择的 official channel，并继续经过完整 official 准入；
- local/local unsigned 不因非权威发现索引自动更新；用户主动导入同 signer/ID 的 signed `.eleb` 可按 ADR-010 替代，unsigned 按 §5 替代。主动导入允许同 signer 任意版本升降；official 已吊销 digest 始终拒绝。

## 7. Local 状态机

local installation 至少持久化：digest algorithm、exact digest、adapter identity、来源提示、创建时间、状态、trust epoch 和 active binding。`disable`、`revoke trust` 与 `delete` 是三种不同操作：

- **disable**：保留 trust、bundle bytes 和 installation record，但阻止执行；重新 enable 不需要重新信任；
- **revoke trust**：保留 bundle bytes 与最小撤销 tombstone，使当前 trust epoch 永久失效；再次信任同一 digest 必须重新展示完整风险并产生新的 epoch；
- **delete**：删除 active binding、trust 和私有 bundle bytes，仅保留不具执行能力的最小审计 tombstone；按 ADR-004 询问用户保留或清空当前 profile 下的 self Credential namespace。重新导入必须重新建立执行信任；若保留 namespace，同 ID 新安装可能接管其中数据，删除页必须明确警告。

grant 是短生命周期、不可持久化的宿主对象，至少绑定 source、digest、adapter identity、installation identity 和 trust epoch。runtime 不得把 grant 退化为可长期复用的 tier 字符串。

disable、revoke 或 delete 必须先持久化状态，再关闭全部 adapter isolate 和任务队列并重建执行面。重建完成前操作不得显示为成功。旧队列、旧 worker 和旧 grant 不能进入新执行面；已发出的外部网络请求可能无法撤回，但其响应不得交回旧 isolate，也不得触发后续 host 副作用。

## 8. Local 与 official revocation 的关系

official revocation 只治理 official 路径。local signed 和 local unsigned 不查询、不展示也不执行 official kill-switch、adapter/version range 或 exact digest revocation。第三方 signer 默认只受用户撤销；未来第三方 revocation source 必须另立 ADR。

在 unsigned 迁移窗口内，用户可以在应用外移除被拒 signed `.eleb` 的 detached signature，再将相同 content digest 作为 local unsigned 明确信任。该过渡选择意味着项目不能强制阻止用户运行已知有害的 unsigned digest；unsigned 删除后不再提供该绕过。local signer 仍不受 official revocation，但受用户保存的 signer trust 与 ADR-010 identity 规则约束。

## 9. 平台与备份门

- Android 和 desktop release build 在过渡期可以铸造 official、local signer 和 local unsigned grant；unsigned 退役后只保留前两者；
- iOS 和 OHOS MVP 只能铸造 official grant，loader 与 runtime 必须强制，不能只隐藏导入 UI；
- OHOS 未来开放 local import 前须另行评审文件导入、备份排除、安全存储和平台动态代码政策；
- local import 不得开放 native transport、raw socket、VPN、TLS 中间人或其他旁路能力。

local signer/unsigned trust record、installation、active binding、tombstone 和 `.eleb` bytes 必须全部排除普通应用备份和跨设备同步。若平台无法证明排除成功，该平台不得启用 local。导出和重新导入不携带 trust；目标设备必须重新确认 signer 或过渡 unsigned digest。

## 10. DEV build trust profile 迁移

新增独立的 `localDigest` grant 和生产安装路径，不得把现有 digest 为 null 的 `devSideload` context 改名复用。

迁移期间，旧 `ELECON_TRUST_PROFILE=dev-sideload` 只能存在于 debug artifact，并继续由 release artifact gate 证明不可达。这里的 DEV/DEPLOY 是旧 **build trust profile**，不是 Credential Store 用户 profile。local signer 开发工具和测试替代门成为 required check 后，删除旧 build trust profile、grant 和对应 runtime 分支。旧 DEV grant 不属于本 ADR 的三条生产路径，也不能写入 production trust store；unsigned 最终退役后 debug 也必须使用隔离开发 signer。

## 11. 必测负例与故障门

V2 执行准入至少覆盖：

- 未确认 local signer 或过渡 unsigned digest 不执行，预检不得执行 module initializer、hook 或 capability；
- 首次 local 安装不因同 ID、同来源或缓存继承 trust；已 active unsigned 只有用户主动导入同 ID 候选且 preflight 通过才可替代；
- 路径、encoding、format 或文件字节变化导致 canonical digest 变化；
- 带 signature 的输入 official 门失败后不得降级 local；
- 临时写入、最终写入、重读校验或 active commit 任一失败均保留旧 active；
- 替换导入源、替换已安装字节、缓存投毒和 TOCTOU 均拒绝；
- disable、revoke、delete 后旧 epoch、旧队列和旧 isolate 均不可执行；
- 同 digest 重新信任产生新 epoch，旧 grant 不复活；
- local/official 同 ID 不自动切换来源；official 不能被 unsigned 普通覆盖；
- backup/restore、系统迁移或导出不能传播 local trust；
- Android/desktop 按迁移阶段接受持久化 local signer/unsigned grant；iOS/OHOS release 无法铸造任何 non-official grant；
- unsigned 退役后所有 artifact 均无 unsigned grant；开发 signer、测试 signer 和导入 bypass 不进入普通 release trust roots；
- official last-good 防 sequence 回滚、拒绝已知吊销且不授权未知新 digest。

对应客户端 loader/runtime 测试成为 required gate 前，不得删除 V1 runtime gate。安全敏感实现和测试必须由人工实质性复核。

## 12. 结果与代价

该决策使 official、第三方 local signer 和过渡 unsigned trust 可解释、可撤销，同时保留 official 的自动信任和离线可用性。代价是新增 signer trust、installation registry、非备份存储、active binding、trust epoch、执行面重建和 unsigned 退役门。

local signed/unsigned 完全不受 official revocation 控制是明确的产品选择，而不是漏检。官方治理只能为 official 路径提供持续背书；用户对 non-official 的选择具有更高权力和更高风险。
