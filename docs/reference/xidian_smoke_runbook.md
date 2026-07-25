# XIDIAN 闭环真机冒烟 Runbook（M2 收尾 / DoD §8）

> **状态：待人工执行**（2026-07-25 起草）。
>
> 🔒 本 runbook 覆盖 **CASTGC 母票收割 → 静默 headless mint → ehall 代取** 的端到端验证，
> **全程触红线 #1**（凭证/句柄永不离核心）。按 [AGENTS.md](../../AGENTS.md) §1 + [ADR-017](../adr/adr_017_sso_master_credential.md) §4.9：
> **实现与冒烟须人工主导 + 安全清单 + ≥1 人工审，AI 不得独自闭环。** 本文件由 AI 起草为执行脚手架，
> **真机操作、日志核验、勾选授权均由人工完成**。
>
> 关联：[`xidian_mint_closed_loop_plan.md`](./xidian_mint_closed_loop_plan.md) §8（DoD）/ §7（PR 切分 M2）；
> [`declarative_dataflow_security_checklist.md`](./declarative_dataflow_security_checklist.md)（红线 #1 审阅范式）。

---

## 0. 前置条件

| 项 | 要求 |
|---|---|
| 构建 | **debug build**（headless minter 仅 debug 自动装配，release fail-closed，见 `session_controller.dart:243` `_wireSsoMinterFor`） |
| 平台 | Android / iOS 真机（Linux 桌面无 WebView 登录，`login_flow.dart` 已挡） |
| 账号 | 真实 XIDIAN IDS 学号 + 密码（**禁止入库/截图/提交**，红线 #8；`getpass` 式即用即弃） |
| 存储档 | 有硬件加密走 S 档；无则弹「无硬件警告」→ 明确选 S 软件档（本机验证足够） |
| 能力 UI | 首页按需取数区（`capability_sections.dart`）：成绩 / 课表 / 空教室 |
| 观测 | debug 下 `DevLog`（`session.debugLog=true`）为唯一 sink；核验用 |

---

## 1. 步骤 → DoD 映射

> 每步先做**操作**，再核验**判据**。判据不满足即停，记录现象，不得为「通过」放宽。

### S1 — 一次可见登录收割母票（DoD #1）
1. 选校 XIDIAN → 首页点「成绩」区「查看成绩」→ 无 `ehall-session` 触发 `ensureCredentials`。
2. 首次无 `ids-cas` 母票 → 走可见 WebView 登录（IDS）。完成滑块 + 登录。
- [ ] **判据**：登录成功后设置页显示已收割凭证含 **`ids-cas`**（通常并含 `ehall-session`，因首登 `login.url` 指向 ehall 目标）。
- [ ] **判据**：`credentialRefs` 不含任何母票域下游明文；设置页只列 ref 名，不显值。

### S2 — 静默 headless mint（DoD #2）
1. 若 S1 已连带收割 `ehall-session`，先在设置页/调试入口**删除 `ehall-session`**，保留 `ids-cas`。
2. 再点「查看成绩」。
- [ ] **判据**：**不弹**可见登录页；后台 `HeadlessSsoMinter` 用母票在 **CAS 端点**换取 `ehall-session`。
- [ ] **判据**：`grades.list` 返回**通过 contract schema** 的结果，首页成绩卡片渲染真实成绩。

### S3 — 删 session 自动重 mint（DoD #3）
1. 再次删除 `ehall-session`（保留 `ids-cas`）→ 点「课表」，选周次 → 查询。
- [ ] **判据**：自动静默 mint，**不**弹登录；`schedule.week` 通过 schema，课表渲染。
- [ ] **判据**：空教室区「加载教学楼」→「查询」同样自动就绪（`classroom.buildings` + `classroom.available`）。

### S4 — 母票失效唯一走可见登录（DoD #4）
1. 删除 `ids-cas`（或构造 tgcExpired：清 IDS 站点 cookie 使 TGC 失效）→ 点任一凭证能力。
- [ ] **判据**：`classifyMintResult` 判 `tgcExpired`/无 master → **唯一**路径是可见 WebView 重登，不静默猜测。

### S5 — 全程无凭证明文（DoD #5）🔒
1. S1–S4 期间开启 `DevLog`，事后导出诊断。
- [ ] **判据**：日志 / 诊断 / adapter isolate 栈 **无** cookie 明文、无 `CASTGC`、无带票 URL、无 `Set-Cookie`。
- [ ] **判据**：注入值在交回 adapter 前经回显剥离（`stripEchoes`，见安全清单 A5）；抽样 body/响应头无残留。

### S6 — 无 ssoMint 假校回归（DoD #6）
1. 选一所无 `ssoMint` 声明的学校（或临时构造）跑同样能力。
- [ ] **判据**：行为退化为旧版逐服务可见登录，无 mint 触发，无异常。

---

## 2. 安全清单闸门（合并前，🔒 人工审）

> headless mint 属协议模拟合规灰度，**不得默认进发版**直至合规评估通过（ADR-017 §4.9）。
> 下列须 ≥1 人工审签字，参照 `declarative_dataflow_security_checklist.md` 的 A 组范式：

- [ ] **G1** 母票注入**仅** CAS 端点：Broker `allow`/`navigationAllow` 不让母票域 cookie 泄到下游业务域（校 `schools.dart` scope 与 `ssoMint.services`）。
- [ ] **G2** adapter isolate 全程**不见**凭证值 / 句柄：`school-xidian` fetch 能力经 broker 注入子 session，manifest `network.allow` 不含 `ids.xidian.edu.cn`。
- [ ] **G3** mint 执行体（`HeadlessSsoMinter`）的 `resolver`/`putCredential`/`transport` **闭包在核心**，UI 零凭证（`session_controller.dart` `_ssoMinter` 生命周期）。
- [ ] **G4** 失败 fail-closed：mint 失败 / 抽取失败 → 整条 capability 失败或降级可见登录，**不**发未认证请求。
- [ ] **G5** debug-only 装配确认：release build 该路径**编译期剔除**（红线 #4/#5），二进制无 headless-imperative mint 入口。
- [ ] **G6** 真实账号未入任何提交 / fixture / 日志导出（红线 #8）。

---

## 3. 结果登记

| DoD | 结果 | 备注/日志摘录（脱敏） | 审阅人 |
|---|---|---|---|
| #1 可见登录收割 | ⬜ | | |
| #2 静默 mint→grades | ⬜ | | |
| #3 删 session 自动 mint | ⬜ | | |
| #4 tgc/无 master 唯可见 | ⬜ | | |
| #5 无凭证明文 | ⬜ | | |
| #6 无 ssoMint 回归 | ⬜ | | |
| 安全闸门 G1–G6 | ⬜ | | |

全部满足 → 回写 `xidian_mint_closed_loop_plan.md` §7 M2「真机冒烟」为完成，并在 §8 DoD 勾选。
