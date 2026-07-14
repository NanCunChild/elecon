# PR #86 人工安全审查清单（feat/webview-login）

> **状态**：待人工勾选。触红线 #1 / #4 / #5 / #7 路径；AI 不得独自闭环（AGENTS.md §1）。  
> **审过后**：① 对应文件头改为「人工审阅通过 YYYY-MM-DD（PR #86）」；② 分支 rebase 补 GPG 签名；③ `Assisted-by` **保留**不删。  
> **关联决策**：adapters 迁 `elecon-adapters`（仅官方）、iOS H/备份下一 PR、威胁模型不含 root/TEE 伪造。

---

## 0. 审阅完成定义

- [ ] 下列 **A–E** 全部勾选或有明确「接受风险 / follow-up issue」
- [ ] PR 描述写明「下列路径已人工安全审」+ 日期 + 审阅人
- [ ] 已审文件源码头「AI 起草，须人工复核」→「人工审阅通过 …（PR #86）」
- [ ] 未审文件 **不得**改文案装已审
- [ ] `git rebase` 补签（或 `git filter`/`reword` 策略由维护者定）后 `git log --show-signature` 干净
- [ ] 骨架类（signer 生产密钥、public 验签、campus relay）**明确仍为 draft**，不因 PR 合入假装可 release

---

## A. 凭证存储（红线 #1 · ADR-012 §2.8）— 优先

| # | 路径 | 审什么 | ☑ |
|---|---|---|---|
| A1 | `client/lib/core/credential/aead.dart` | AES-GCM 用法、nonce、失败 fail-closed；无自造原语 | |
| A2 | `client/lib/core/credential/software_secure_store.dart` | DEK 生成/轮换、落盘格式、整库原子 rename | |
| A3 | `client/lib/core/credential/hardware_secure_store.dart` | 信封：value AEAD + wrapDek；unwrap 失败语义 | |
| A4 | `client/lib/core/credential/hardware_keystore*.dart` + `HardwareKeystorePlugin.kt` | 通道不可被 Dart 侧伪造 KEK；DEK 32B；StrongBox→TEE；错误不泄密钥材料 | |
| A5 | `client/lib/core/credential/secure_store_factory.dart` | H→S/M 裁定；无硬件时必须经知情同意 | |
| A6 | `client/lib/core/credential/blob_store.dart` + `main.dart` 目录 | 仅 app 私有 `…/credentials`；与 Android 备份排除路径一致 | |
| A7 | Android `allowBackup=false` + `backup_rules` / `data_extraction_rules` | 排除 `credentials/`（及 `app_flutter/credentials/`） | |
| A8 | `client/lib/ui/security/no_hardware_warning_dialog.dart` | 强制等待 + 明示风险；不可绕过静默落 S | |
| A9 | `client/lib/session/session_controller.dart` + logout | 按 `schoolId` 抹除；无跨校误清；值不进日志 | |
| A10 | 测试：`credential/*`、`session_store_wiring_test` | 不断言真实密钥；负例（篡改 blob）存在 | |

**范围外（本 PR 不要求）**：iOS H / iOS 备份排除（下一 PR）；OHOS/桌面 H；反 root。

---

## B. WebView 登录与收割（红线 #1 · ADR-015/016）

| # | 路径 | 审什么 | ☑ |
|---|---|---|---|
| B1 | `client/lib/core/login/webview_login.dart` | cookie **值**只进核心收割；调用方 API 无 value 外泄 | |
| B2 | `client/lib/ui/login/webview_login_page.dart` | 导航 allow 闭锁；越界停；成功判据；TLS/证书策略 | |
| B3 | 收割有界轮询（替代固定 600ms） | 超时/失败路径；不空转泄 cookie | |
| B4 | debug 日志面板 | 凭证/cookie 打码（`_maskCookie` 等）；release 无多余日志 | |
| B5 | `webview_login_harvest_xidian_test.dart` 等 | 夹具脱敏；覆盖声明 scope / 不收未声明域 | |
| B6 | `schools.dart` CAS `service` 占位 | 知悉仍为占位；真机前须校准（可开 follow-up，不装已完成） | |

---

## C. Broker 注入 / 边界（红线 #1 · ADR-009/013/017）

| # | 路径 | 审什么 | ☑ |
|---|---|---|---|
| C1 | Dart：`assemble` / `inject_policy` / `url_match` / `cookie_match` / `header_sanitize` / `redirect` / `harvest` / `cookie_jar` / `fetch_proxy` | 最长前缀；allow 外不注入；redirect 不泄 Location 敏感；adapter 写 jar 边界 | |
| C2 | TS 镜像：`server/src/runtime/broker/*` 同上 | 与 Dart **行为一致**（含 fail-closed 点） | |
| C3 | `packages/broker-primitives` + `contract/broker/public-suffixes.json` | 单源后缀；两侧消费正确 | |
| C4 | 母凭证 CASTGC（ADR-017 PR-2） | 仅 CAS 域收割；**不**随子 session 外注；scope 与数据域不重叠（M4） | |
| C5 | `sso_mint.dart` | **仅**纯逻辑/接口；无执行体注入母票（执行体仍人工后续 PR） | |
| C6 | 对应 `client/test/broker_*` + server `*.smoke.ts` | 负例齐全；AI 未放宽断言 | |

---

## D. 信任闸门与运行时（红线 #1/#4/#5 · ADR-002）

| # | 路径 | 审什么 | ☑ |
|---|---|---|---|
| D1 | `client/lib/core/trust/trusted_context.dart` + server `trusted-context.ts` | 防伪造签发；未登记 token 拒；与 PR #80 结论一致 | |
| D2 | `client/lib/core/adapter_runtime.dart` + server `sandbox.ts` | fetch 必经信任上下文；release 无侧载-fetch；凭证不进 JS | |
| D3 | `client/lib/core/transport/direct.dart` + server `transport/direct.ts` | 注入后出网；无日志明文凭证 | |
| D4 | OOM / `bad_export` 词表双端 | 归类一致；不吞安全错误为成功 | |

---

## E. 签名 / 分发 / 中继骨架（红线 #4/#2/#3）— 审「未越权」

| # | 路径 | 审什么 | ☑ |
|---|---|---|---|
| E1 | `tools/src/signer/*` | digest 规范化符合 ADR-002；**生产签/KMS 仍未闭环**；dev 后端不可进用户分发 | |
| E2 | `server/src/public/*` | 零凭证；验签 gate **未接线则 501** 可接受；无「未验签却 200 分发」 | |
| E3 | `server/src/campus/*` | relay **ADR-blocked**；无假实现落盘凭证 | |
| E4 | 合入后是否误导 release | README/注释仍标明 draft，无「可签名上架」暗示 | |

---

## F. 非安全但建议扫一眼（可降级）

| # | 项 | ☑ |
|---|---|---|
| F1 | codegen 消费 + CI 漂移闸门 | |
| F2 | npm workspace / Biome / smoke 发现 | |
| F3 | UI 壳 / 设置登录态（无凭证值） | |
| F4 | `flutter_qjs_next` pin 与 CI 库路径 | |

---

## 审阅通过后的机械步骤（维护者）

```bash
# 1) 改文件头：仅已勾选文件
#    「AI 起草，须人工…」→「人工审阅通过 2026-MM-DD（PR #86）；后续改动仍须安全清单。」

# 2) 补 GPG（历史若曾 --no-gpg-sign）
git rebase --exec 'git commit --amend --no-edit -S' <base>   # 或维护者惯用补签流程
git log --show-signature -5

# 3) PR 评论贴：已审文件列表 + 未审/follow-up（iOS、SSO mint 执行体、KMS、elecon-adapters）
```

**禁止**：force 改写以删除 `Assisted-by`；未审文件改「已审」；把 signer/public 标成生产可用。

---

## 本 PR 明确不阻塞 / 下一 PR

| 项 | 说明 |
|---|---|
| iOS 工程 + 备份排除 + H 档 | **下一 PR** |
| SSO mint **执行体** | 人工主导后续；本 PR 仅接口 |
| `elecon-adapters` 迁出 | 官方仓；本 PR 可只留决策，迁仓另开 |
| OIDC→KMS | 首次用户 release 前硬 deadline，非本 PR 合入条件 |
| OHOS/桌面 H | backlog |

---

## 审阅记录（人工填写）

| 日期 | 审阅人 | 范围（A–E） | 结论 |
|---|---|---|---|
| | | | 通过 / 有条件通过 / 打回 |
