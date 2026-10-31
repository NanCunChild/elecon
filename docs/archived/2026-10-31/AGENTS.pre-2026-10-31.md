> **已废弃 / Archived（2026-10-31）**：原路径 `AGENTS.md`。不再作为新开发总则；正文的历史决定、签收和未完成记录原样保留。当前基线见[架构入口](../../architecture.md)；未迁移 V1 的维护边界见[兼容说明](../../reference/legacy_compatibility.md)。本文不产生新的开发指令。

# AGENTS.md · elecon 开发总则

> 本文是 AI 辅助开发与人工贡献的**总则**，**所有人**和**所有 AI**工具在修改代码前必须先阅读本文。
> 用 Claude Code / 其他 agent 工具时，可把 `CLAUDE.md` 软链到本文：`ln -s AGENTS.md CLAUDE.md`。
> 细则见 [`docs/rules/`](../../rules)；架构设计理由见 [`docs/adr/adr_000_abstract.md`](docs/adr/adr_000_abstract.md)。

elecon 是面向学生的校园信息聚合平台。架构第一目标是**在最少人力下对学校接口变动与多平台差异保持韧性**。这决定了一切规则的取向：**优先可热替换、优先隔离、优先把适用最小信任原则。**

---

## 当前路线变更（2026-10-29）

所有者已授权 ADR-034 的受信学校脚本路线。新 `elecon-script/1` 路径中：用户确认后可侧载未签名源码；受信脚本可直接读写当前学校身份的凭据，通过宿主网络与浏览器 API 编排认证。以下 #1/#4/#5 中“adapter 永不见凭据 / DEPLOY 仅 official”的旧约束**只继续约束 V1 official bundle 路径**，不得用于阻断 ADR-034 新路径，也不得借新路径放宽未迁移的旧入口。加密主密钥、其他身份、任意原生能力不开放。其余红线继续生效。实现审阅与生产合并仍须区分，自动测试不得声称人工安全签收。

## 0. 不可违背的红线（Invariants）

以下是架构的承重墙。**任何代码、任何 AI 生成的改动，都不得违背。触碰即拒绝合并。** AI 在产出前必须逐条自检（见 [`docs/rules/ai_coding.md`](docs/rules/ai_coding.md)）。

1. **凭据访问按执行路线裁定。** ADR-034 的受信学校脚本可直接读写当前授权学校身份的凭据；加密主密钥、其他学校或账号的凭据不开放，UI 不取得完整凭据库。V1 official bundle 的 adapter / UI 仍不得取得凭据值及等价物（带 token 的 URL、`Set-Cookie`、重定向中间 token）。公网服务端始终不持凭据。
2. **公网服务端零凭证、无状态。** 不得为公网哑服务（`server/src/public`）添加任何凭证存储或私密数据持久化。
3. **私密数据不经公网。** 私密 / 认证数据只走客户端直连或校内授权中继（`server/src/campus`）。
4. **执行必须来自明确授权。** `elecon-script/1` 通过用户确认包内容、身份与网络范围建立本地安装授权，允许未签名源码；版本更新重新确认且执行内容必须匹配授权 digest。V1 official bundle 无论来自 catalog 还是本地文件仍须通过 official 验签、身份绑定与吊销门；ADR-033 的 V1 bundle 本地导入尚未落地。不得把新源码路径的授权当作旧 bundle 验签凭据，也不得把旧 DEV-only 规则套用于新源码路径。transport 编译进应用，不开放脚本原生模块侧载。
5. **学校流程由脚本承担，宿主约束执行能力。** 新受信脚本可自行处理认证、签名、请求与 DOM，仍使用背景执行、当前身份存储和声明的域名/IP 网络范围，不获得任意文件、进程、FFI 或 raw socket。V1 adapter 继续遵守 ADR-000/002 的受限 Broker 能力面；新脚本不要求 requestGraph、opaque handle 或 Masker。旧机制仅作迁移兼容保留，尚未全局删除，不再扩充校本算子（ADR-034）。
6. **契约即承重墙。** 改动 `contract/`（schema、manifest）必须先有 ADR，在现阶段可以出现破坏性更新，在公测阶段完成且版本号稳定后，由人工决定是否应当修改为兼容考虑。
7. **adapter 不在 UI 线程同步执行。** 一律背景 isolate，UI 永远异步。
8. **不提交真实学生数据。** 测试夹具必须脱敏。
9. **新依赖须声明许可证。** GPL 系组件必须做进程 / 模块边界隔离以避免传染（见 ADR）。
10. **架构性改动先写 ADR。** 实现中若发现需要改动核心或契约，**停下来开 ADR**，不得在 feature 里直接重构核心。

---

## 1. 怎么工作

- **先读后写**：动手前读 ADR-000 + 与改动相关的 `docs/rules/` 细则；改契约/核心还要读对应细分 ADR。
- **小步提交、单一目的**：一个 PR 只做一件事，便于审查（尤其是安全敏感路径）。
- **声明合规**：每个 PR 说明它遵循/不破坏哪条 ADR 与红线（PR 模板里有勾选项）。
- **AI 提议，人负责**：AI 可以写大段代码，但合并的责任在人。安全敏感路径（核心 / 凭证 / 传输 / 签名）的代码与其测试不得由 AI 独自闭环，必须人工审阅。

---

## 2. 规则索引

| 细则 | 覆盖 |
|---|---|
| [`docs/rules/feature_workflow.md`](docs/rules/feature_workflow.md) | 新功能加入方式：快/慢车道、何时需要 ADR |
| [`docs/rules/git.md`](docs/rules/git.md) | 分支模型、commit 规范、PR 规范 |
| [`docs/rules/testing.md`](docs/rules/testing.md) | 测试原则：信任越高测试越严、夹具驱动 |
| [`docs/rules/ai_coding.md`](docs/rules/ai_coding.md) | AI 编程纪律与产出前自检清单 |
| [`docs/rules/ui_ai_generation.md`](docs/rules/ui_ai_generation.md) | AI 生成 Flutter UI 的边界（ADR-004 框内、Material 3） |
| [`docs/glossary.md`](docs/glossary.md) | 术语与编号速查（信任域 A–D、P0–P4、三种 envelope、DEPLOY/DEV-Sideload…） |

**状态源**：决策状态看 [`docs/adr/README.md`](docs/adr/README.md)，执行 / 签收状态看 [`docs/planning/2026_08_review_remediation.md`](docs/planning/2026_08_review_remediation.md)；ADR-034 新受信脚本路线的执行状态看 [`docs/planning/trusted_scripts.md`](../../planning/trusted_scripts.md)。其它进度描述是快照，冲突时以对应路线的状态源为准。
