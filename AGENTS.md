# AGENTS.md · elecon 开发总则

> 本文是 AI 辅助开发与人工贡献的**总则**，**所有人**和**所有 AI**工具在修改代码前必须先阅读本文。
> 用 Claude Code / 其他 agent 工具时，可把 `CLAUDE.md` 软链到本文：`ln -s AGENTS.md CLAUDE.md`。
> 细则见 [`docs/rules/`](docs/rules/)；架构设计理由见 [`docs/adr/adr_000_abstract.md`](docs/adr/adr_000_abstract.md)。

elecon 是面向学生的校园信息聚合平台。架构第一目标是**在最少人力下对学校接口变动与多平台差异保持韧性**。V2 将 adapter 视为项目或用户选择信任的本地程序：优先可热替换、降低贡献门槛，并把强制边界收敛到执行准入、QuickJS 隔离、宿主网络出口、公网零凭证与 transport。V2 总纲见 [`ADR-000`](docs/adr/adr_000_abstract.md)。

---

## 0. 不可违背的红线（Invariants）

以下是架构的承重墙。**任何代码、任何 AI 生成的改动，都不得违背。触碰即拒绝合并。** AI 在产出前必须逐条自检（见 [`docs/rules/ai_coding.md`](docs/rules/ai_coding.md)）。

1. **未受信 adapter 永不执行。** official adapter 通过官方验签、身份绑定、吊销与兼容门后自动受信；支持本地导入的平台可由用户按 bundle digest 整体信任 local unsigned adapter。受信 adapter 可读写全部 Credential Store、读取私密响应并使用 adapter 能力；项目不承诺阻止其泄漏或篡改这些数据。MVP 不实现用户自签或签名者信任。iOS 仅运行 official，loader/runtime 必须强制，不能只隐藏入口（ADR-000 §3.1、§5.1）。
2. **公网服务端零凭证、无状态。** 不得为公网哑服务（`server/src/public`）添加任何凭证存储或私密数据持久化。
3. **私密数据只在用户设备侧。** 私密 / 认证数据只由客户端经 direct、系统 VPN 或 official transport/app-tunnel 访问学校；项目不提供校内授权中继，`server/src/public` 不执行 adapter、不接触凭证或私密响应（ADR-001 §4.1–§4.4）。
4. **传输底座仅官方加载。** adapter 的本地导入自由不得扩展到 transport。transport 仍只随官方应用分发，不向 adapter 或本地 bundle 开放原生模块、raw socket、VPN 或 TLS 中间人能力；dev transport 仍只在 debug build 存在。
5. **adapter 网络只有宿主出口。** adapter 不得获得 raw socket、Node 网络模块、WebView、原生 FFI 或旁路网络能力；所有请求必须经过宿主，强制 scheme / origin / path / method、逐跳重定向和资源预算。出网门只限制目标和资源，不承诺识别 adapter 编码进获准请求的凭证或私密数据（ADR-000 §5.3）。
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
| [`docs/rules/feature_workflow.md`](docs/rules/feature_workflow.md) | 新功能加入方式：快/慢车道、何时需要 ADR |
| [`docs/rules/git.md`](docs/rules/git.md) | 分支模型、commit 规范、PR 规范 |
| [`docs/rules/testing.md`](docs/rules/testing.md) | 测试原则：信任越高测试越严、夹具驱动 |
| [`docs/rules/ai_coding.md`](docs/rules/ai_coding.md) | AI 编程纪律与产出前自检清单 |
| [`docs/rules/ui_ai_generation.md`](docs/rules/ui_ai_generation.md) | AI 生成 Flutter UI 的边界（有界组件、标准 schema、Material 3） |
