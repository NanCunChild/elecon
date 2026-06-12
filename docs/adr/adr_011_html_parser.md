# ADR-011：adapter HTML 解析（SDK 内置纯 JS 解析器，零漂移）

- **状态**：**草案（Proposed）** ⚠️ 本文改动 **adapter SDK 表面（`contract/adapter-sdk/`）+ 两端运行时 moduleHandler**——触及契约与 runtime（红线 #6 契约即承重墙、#10 架构性改动先写 ADR）。**不碰网络/凭证**（非红线 #1），但碰运行时与契约，按草案走人工审阅后才实现。
- **日期**：2026-06-12
- **依赖**：[`adr_001_contract.md`](./adr_001_contract.md)（SDK 类型 / 契约）、[`adr_005_runtime.md`](./adr_005_runtime.md)（服务端 QuickJS-wasm）、[`adr_008_client_runtime.md`](./adr_008_client_runtime.md)（客户端 QuickJS + moduleHandler + engine-floor canary）、[`adr_009_fetch_credential.md`](./adr_009_fetch_credential.md)（fetch 模式响应体同样复用本解析器）
- **被依赖**：HTML 源 adapter（首例 XIDIAN `notice.list`，见 §4）
- **适用范围**：adapter 在 QuickJS 内**解析 HTML** 的能力如何提供。**不含** JSON 解析（已可 `JSON.parse`）、不含 JS 挑战/反爬执行（见 §3.4 与 ADR-009）、不含某校具体 adapter。

---

## 1. 背景（Context）

首批逆向 adapter（XIDIAN / XJT 教务通知公告）暴露一个共性事实：**很多学校的通知公告是 HTML 页面、无 JSON feed**，adapter 必须从 HTML 抓取。而当前运行时**完全没有 HTML 解析能力**：

- `ctx` 只给 `log`/`now`（parser）或 `fetch`/`log`/`now`（fetch），**无 DOM**（`contract/adapter-sdk/types.d.ts`）。
- 客户端 QuickJS 是 Bellard **2021-03** 版（ADR-008 §3.6），**无 DOM、无 ES2022+、无 BigInt**。
- 现有模板 adapter 全靠 `JSON.parse`——HTML 抓取目前**无支持**。

需求：给 adapter 一个能写"层级定位"（如 XIDIAN 的 `找'通知公告'锚点 → 上溯 div.tit → 取兄弟 ul → 遍历 li`）的 HTML 解析手段，**且不破坏"一份 adapter 两端同一引擎、零漂移"的承重墙**（ADR-005/008）。

---

## 2. 决策（Decision，草案）

> 以下为**待审议**取向，非既定事实。每条都需审阅确认。

### 2.1 解析器是「QuickJS 内执行的纯 JS 共享模块」，不是 host 原生 `ctx` 函数

- **决定性理由（零漂移）**：若由 host 原生提供（客户端 Dart 一个 HTML 解析器、服务端 Node 一个），两个 tag-soup 实现对**畸形 HTML 的容错行为必然不同** → 同一页面两端解析结果可能不一致 → **双跑 golden 飘**，直接打穿 ADR-005/008 的零漂移墙（与"客户端别用 JavaScriptCore""服务端别用 goja"是同一类理由）。
- **形态**：**一份纯 JS 解析器**作为 SDK 模块，经 ADR-008 的 `moduleHandler` 以固定模块名（建议 `elecon:html`）解析；**两端加载同一份源码、各自在 QuickJS 内执行** → 与 adapter 同引擎、零漂移。
- 解析器**自身遵守引擎地板**（无 ES2022+ / 无 BigInt），挂 engine-floor 约束并纳入双跑闸门（ADR-008 §3.6 canary）。

### 2.2 API：DOM-lite，够用即止（不做完整 CSS 引擎）

- `parse(html: string): Node` → 根节点。
- `Node`：`{ tag, attrs: Record<string,string>, children: Node[] }` + 方法：
  - `text(): string`（拼接子孙文本）
  - `attr(name): string | null`
  - `find(selectorOrPredicate): Node | null` / `findAll(...): Node[]`
  - `closest(selector)`（上溯祖先，覆盖"上溯 div.tit"）
  - `next(selector?)`（下一个兄弟元素，覆盖"取兄弟 ul"）
- **selector 子集**：`tag`、`.class`、`tag.class`、`[attr]`/`[attr=val]`，以及任意 `(node) => boolean` 谓词（覆盖"按文本等于'通知公告'定位"）。**不支持**后代/子组合器、伪类等——YAGNI，按真实 adapter 需求增量扩。
- **明确非目标**：不渲染、不计算样式、**不执行内联 JS / 不跑 `<script>`**。

### 2.3 容错与确定性（双跑一致性的新承重点）

- tag-soup 容错策略（未闭合标签、可选闭合的 `li`/`p`、void 元素 `br`/`img`/`meta` 等）**必须固定且文档化**——它直接决定两端是否一致。
- **确定性硬要求**：同一输入两端必须同一输出（golden）。容错规则一经确定，**其改动等同契约改动**（红线 #6），走 ADR / 版本化，不得随手改。

### 2.4 选型：自写极简 vs vendor 微型库

| 取向 | 取 | 舍 |
|---|---|---|
| **自写极简（建议）**（~150–250 行，零依赖、引擎地板安全、可审计） | 可控、无许可证/传染问题、体积最小、容错规则我们说了算（利于双跑） | 自维护一个解析器 |
| vendor 微型 htmlparser | 省自写 | 多数库用了 ES2022+/正则新特性需移植核对引擎地板；许可证（红线 #9）；容错规则不可控 → 双跑风险 |

**取向**：先**自写极简**覆盖 `notice.list` 类层级定位；长尾页面复杂度上升再评估 vendor。

---

## 3. 已知约束与风险（Consequences，草案）

1. **容错差异是双跑飘移的新风险面。** 解析器自身必须挂 canary/双跑；规则改动按契约处理（§2.3）。
2. **体积/性能。** 两端 bundle 各加解析器源码；notice 类小页面无压力，但需对"大页面 × QuickJS"做基准，避免在 UI 端拖慢（background isolate 已兜，ADR-008 §2.2）。
3. **安全：纯解析、无副作用。** 不碰网络/凭证（非红线 #1）。但 parser 模式喂的是公开数据响应、fetch 模式可能喂私密响应——解析器**无网络能力**即天然不外泄；不得引入任何 I/O。
4. **不解决 JS 挑战 / 反爬。** XJT 类"解析内联 JS 算 answer + 伪造指纹"需在 **fetch 模式**执行握手，**不在本解析器职责内**（见 [`adr_009`](./adr_009_fetch_credential.md) 的 HTML/多步贴合说明）。
5. **selector 子集的度。** 过窄逼 adapter 写丑逻辑、过宽变成维护 CSS 引擎——按真实需求增量扩，避免镀金（§2.2）。

---

## 4. 落地清单（待 ADR 接受后，拆成可审查的小 PR）

- **SDK**：`contract/adapter-sdk/` 增 `elecon:html` 模块类型声明（`Node` / DOM-lite 接口）。
- **运行时**：两端 `moduleHandler` 注册 `elecon:html` → **同一份**纯 JS 解析器源码（客户端 `flutter_qjs`、服务端 `quickjs-emscripten`）。
- **解析器**：自写极简 + 固定容错规则；engine-floor 合规；挂 canary / 双跑。
- **测试**：解析器单测（畸形 HTML 容错矩阵）+ 双跑一致性 + XIDIAN `notice.list` 端到端 golden。
- **文档**：adapter 编写指南补"HTML 源 adapter"小节 + selector 子集说明。
- **首例落地**：XIDIAN `notice.list`（parser 模式）——已先以 `adapters_tests/` spike 验证 API 形态（本 ADR 配套）。
