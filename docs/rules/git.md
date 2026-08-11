# 规则 · Git（分支 / Commit / PR）

配合 [`AGENTS.md`](../../AGENTS.md) 阅读。原则：**人力有限，流程越轻越好；信任越高的改动，闸门越重。**

---

## 1. 分支模型

主干式（trunk-based），`main` 始终可发布、受保护、禁止直推。功能在**短命**分支上做，尽快合回。

分支命名：`<type>/<简短描述>`，type 取：

| 前缀 | 用途 |
|---|---|
| `feat/` | 新功能 |
| `fix/` | 缺陷修复 |
| `adapter/<school-id>` | 单个学校 adapter（走快车道，见 feature-workflow） |
| `docs/` | 文档 / ADR |
| `chore/` | 构建、依赖、工具链 |
| `refactor/` | 不改行为的重构 |

> **adapter 分支是特例**：因为 adapter 隔离、可热替换、坏了只影响一个数据源，它走更快的审查车道。但改动一旦碰到 `contract/` 或核心，就不再是 adapter 改动，按 `feat/` 处理。

---

## 2. Commit 规范

采用 **Conventional Commits**：`type(scope): subject`

- **type**：`feat` / `fix` / `docs` / `test` / `refactor` / `chore` / `perf`
- **scope**：对应模块，建议取 `core` / `broker` / `runtime` / `transport` / `plugin` / `contract` / `adapter` / `server` / `client` / `ui`
- **subject**：祈使句、小写开头、不超过 ~50 字符、结尾不加句号

示例：

```
feat(adapter): 新增 school-1234 课表归一化
fix(broker): 修复白名单外请求误注入凭证
docs(adr): 起草 adr_001 manifest v2 规范
```

约定补充：

- 触碰**红线相关路径**（core / credential / transport / 签名）的 commit，body 里写明影响与缓解。
- **AI 生成的改动**在 body 加一行 `Assisted-by: <工具名>`，提示审阅者这段需人眼复核（尤其安全敏感路径）。
- 一个 commit 一个逻辑变更，别把格式化和逻辑改动混在一起。

---

## 3. PR 规范

- **小而单一**：一个 PR 一个目的；大改先拆分。
- **禁止直推 `main`**：一律经 PR + 审查。
- **必须声明合规**：PR 描述里勾选"本改动遵循/不破坏的红线与 ADR"。
- **必须带测试**：见 [`testing.md`](testing.md)；无测试的逻辑改动不予合并。
- **分级审查**：
  - 普通 adapter / UI 卡片 → 1 人审，快车道；
  - 触碰 `contract/`、`core/`、`transport/`、签名/吊销 → **至少 1 名人工审阅 + 安全检查清单**，AI 不得独自闭环。
- **CI 必过**：契约一致性、adapter 静态校验、fixture 回归、lint、QuickJS 隔离、宿主出网边界、official 验签/local digest trust、iOS official-only 和客户端 release 产物检查。CI 细项随 V2 后继 ADR 落地，禁止用删除旧断言代替新门禁。

### PR 描述模板

见`.github/pull_request_template.md`文件描述
