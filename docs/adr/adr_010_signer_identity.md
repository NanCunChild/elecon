# ADR-010：adapterId、第三方签名与 namespace 连续性

- **状态**：已接受（Accepted）
- **日期**：2026-08-12
- **依赖**：[ADR-002](./adr_002_execution_trust.md)、[ADR-004](./adr_004_credential_store.md)、[ADR-005](./adr_005_adapter_v2.md)、[ADR-006](./adr_006_official_governance.md)

## 1. 背景

`adapterId` 同时用于 active installation 和 Credential Store namespace。unsigned bundle 可以自报任意 ID，不能证明作者连续性；第三方签名可以证明两个 bundle 由同一私钥控制，但不能自动证明作者可信或成为 official。

本 ADR 定义 ADR-002 的 `local` 第三方 signer trust、更新连续性和 identity 冲突时的凭证生命周期。它必须在 local signed 生产路径启用前接受并落地；local unsigned 仅按 ADR-002 保留一个短暂退役窗口。

## 2. adapterId

`adapterId` 是作者指定的稳定应用身份，效力类似 Android application ID。contract 强制使用规范化反向域名格式、ASCII lowercase 和唯一 canonical form；大小写、尾点、Unicode 混淆或非 canonical ID 拒绝。

作者负责选择全局唯一 ID。客户端只保证本机安装冲突规则；official 发布治理保证 official ID 唯一。项目不要求 local/third-party ID 进入中央注册表。

每个 profile 的一个 `adapterId` 只有一个 active installation，并拥有 ADR-004 定义的同名 Credential namespace。

## 3. Signer identity 与首次信任

第三方 signer identity 是 `SHA-256` over RFC 8032 32-byte raw Ed25519 public key，canonical 文本为 64 个 lowercase hex 字符。`keyId` 和 manifest 作者名只用于展示，不参与 identity、trust 或冲突判定。未知 signer 的有效签名只证明来源连续性，不自动产生执行信任或 official 身份。

首次安装 `(profileId, adapterId, signer fingerprint)` 时，用户必须确认 signer fingerprint、exact digest、网络声明、跨 namespace 模式和整体风险。确认后保存 signer trust。MVP 不支持无损密钥轮换；公钥变化就是 signer identity 不一致。未来连续轮换必须另立 ADR。

## 4. 更新连续性

同 `adapterId`、同 signer 的新 `.eleb` 由用户导入或未来受信更新源交付后，验签、canonical digest、compatibility 和静态门全部通过即可替代旧安装并保留该 profile 下的 namespace，不再对每个 digest 重复确认。用户主动导入允许任意版本升降，不以当前版本或发现索引阻断。

该规则不自行开放后台更新。更新源、下载、回滚和吊销由发布治理 ADR 另行裁定。

若新 manifest 扩大以下任一范围，替代前仍须展示 diff 并确认：

- 新 network scheme、origin、port、path 或 method；
- 新增明文 HTTP；
- 新增跨 namespace target 或扩大 `read`、`write`、`delete` 模式；
- 其他后继 ADR 标记为高风险扩权的宿主能力。

权限不变或收缩时可立即替代。取消扩权确认必须保留旧安装、旧 signer trust 和全部凭证。

## 5. Unsigned 连续性

unsigned installation 没有可验证 signer。用户主动导入同 `adapterId` 的新 unsigned bundle时，完成 bounded preflight 后即可立即替代旧 unsigned 并保留 namespace，不对新 digest 再次确认。

这意味着任何来源都能制作同 ID unsigned bundle；用户主动导入它即可让新代码接管该 namespace。首次 unsigned 风险说明必须明确该后果，不得把 adapterId 描述成作者真实性证明。

unsigned 转为 signed 时，用户首次确认 signer 和权限后可以替代并保留 namespace，之后进入 signer 连续性规则。

## 6. Identity 冲突与强制替换

以下普通覆盖必须拒绝：

- signed installation 被 unsigned bundle 覆盖；
- third-party signer A 被 signer B 覆盖；
- official 被 unsigned 或 third-party signer 覆盖。

用户仍可选择破坏性的强制替换。客户端先执行 bounded unpack、digest、schema、签名和 identity conflict preflight，不运行候选代码；随后二次确认将永久删除当前 profile 下该 `adapterId` 的旧安装、signer trust 和完整 Credential namespace。

用户确认后按以下非原子恢复语义执行：

1. 停止并销毁旧 runtime、任务和 grant；
2. 删除旧 installation 与 signer trust；
3. 清空当前 profile 下该 `adapterId` 的完整 Credential namespace；
4. 再把候选作为全新安装继续处理。

若第 4 步失败，不恢复旧 adapter、trust 或凭证。这是 owner 明确接受的不可恢复数据丢失语义。候选完成 preflight 前不得触发删除，普通导入确认不能代替破坏性二次确认。

## 7. Official 单向接管

official 是唯一例外：用户明确触发切换到同 `adapterId` official 后，即使当前 installation 是 unsigned 或不同 third-party signer，也可以保留 namespace。非权威发现索引中出现 official 仍不能自动改变 active source。

从 official 切换到任何 non-official 必须按 §6 强制替换并清空。official 身份和签名闭合仍由 ADR-006 治理，第三方 signer trust 不得伪造 official 单向接管权。

## 8. 必测负例

- adapterId 非 canonical 反向域名格式拒绝，大小写和 Unicode 不能制造别名。
- 未确认 signer 不执行；密码学有效签名不自动成为 official。
- 同 signer 同 ID 更新保留 namespace；权限扩张未经确认不替代。
- unsigned 同 ID 主动导入可替代并保留凭证，风险页明确其不可验证连续性。
- signed 不能被 unsigned 普通覆盖；signer A 不能被 B 普通覆盖。
- identity 冲突候选 preflight 失败不能删除旧状态。
- 破坏性确认后先删除旧状态；新安装失败不恢复凭证。
- official 接管 non-official 可保留 namespace，但不能由发现索引自动切换。
- official 切出必须清空；跨 profile 永远不能继承、替换或清空其他 profile 凭证。
