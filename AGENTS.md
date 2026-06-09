# AGENTS.md · elecon 开发总则

> 本文是 AI 辅助开发与人工贡献的**总则**，**所有人**和**所有 AI**工具在修改代码前必须先阅读本文。
> 用 Claude Code / 其他 agent 工具时，可把 `CLAUDE.md` 软链到本文：`ln -s AGENTS.md CLAUDE.md`。
> 细则见 [`docs/rules/`](docs/rules/)；架构设计理由见 [`docs/adr/adr_000_abstract.md`](docs/adr/adr_000_abstract.md)。

elecon 是面向学生的校园信息聚合平台。架构第一目标是**在最少人力下对学校接口变动与多平台差异保持韧性**。这决定了一切规则的取向：**优先可热替换、优先隔离、优先把适用最小信任原则。**

---

## 0. 不可违背的红线（Invariants）

以下是架构的承重墙。**任何代码、任何 AI 生成的改动，都不得违背。触碰即拒绝合并。** AI 在产出前必须逐条自检（见 [`docs/rules/ai-coding.md`](docs/rules/ai-coding.md)）。

1. **凭证永不离开核心。** cookie / token 只存于可信核心；adapter、UI、公网服务端永远拿不到凭证的值，也拿不到任何等价物（带 token 的 URL、`Set-Cookie`、重定向中间 token）。
2. **公网服务端零凭证、无状态。** 不得为公网哑服务（`server/src/public`）添加任何凭证存储或私密数据持久化。
3. **私密数据不经公网。** 私密 / 认证数据只走客户端直连或校内授权中继（`server/src/campus`）。
4. **传输底座仅官方签名加载。** release 包内**无侧载入口**；dev 传输只在 debug build 存在。
5. **adapter 越薄越好。** 只做归一化；第三方 / 侧载 adapter 必须是**纯解析器**（无网络、无凭证、无副作用）。
6. **契约即承重墙。** 改动 `contract/`（schema、manifest）必须先有 ADR，且默认保持向后兼容。
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
| [`docs/rules/feature-workflow.md`](docs/rules/feature_workflow.md) | 新功能加入方式：快/慢车道、何时需要 ADR |
| [`docs/rules/git.md`](docs/rules/git.md) | 分支模型、commit 规范、PR 规范 |
| [`docs/rules/testing.md`](docs/rules/testing.md) | 测试原则：信任越高测试越严、夹具驱动 |
| [`docs/rules/ai-coding.md`](docs/rules/ai_coding.md) | AI 编程纪律与产出前自检清单 |
