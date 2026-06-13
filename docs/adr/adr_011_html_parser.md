# ADR-011：adapter HTML 解析（SDK 内置纯 JS 解析器，零漂移）

- **状态**：**草案（Proposed）** ⚠️ 本文改动 **adapter SDK 表面（`contract/adapter-sdk/`）+ 两端运行时 moduleHandler**——触及契约与 runtime（红线 #6 契约即承重墙、#10 架构性改动先写 ADR）。**不碰网络/凭证**（非红线 #1），但碰运行时与契约，按草案走人工审阅后才实现。
- **日期**：2026-06-12
- **依赖**：[`adr_001_contract.md`](./adr_001_contract.md)（SDK 类型 / 契约）、[`adr_005_runtime.md`](./adr_005_runtime.md)（服务端 QuickJS-wasm）、[`adr_008_client_runtime.md`](./adr_008_client_runtime.md)（客户端 QuickJS + moduleHandler + engine-floor canary）
- **关联**：[`adr_009_fetch_credential.md`](./adr_009_fetch_credential.md)（fetch 模式响应体同样复用本解析器，但 HTML 解析本身不依赖 fetch 模式的存在）
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
- htmlparser2 编译产物为 ES5 兼容（验证通过），**天然遵守引擎地板**（无 ES2022+ / 无 BigInt）；bundle 纳入双跑闸门确保两端加载一致（ADR-008 §3.6 canary）。

### 2.2 API：htmlparser2 + domutils 的 DOM-lite 表面

adapter 通过 `elecon:html` 模块获得以下能力（底层由 htmlparser2 + domutils + css-select 提供）：

- `parse(html: string): Document` → htmlparser2 的 `parseDocument` 输出。
- **节点遍历**：`domutils` 提供的 `getText`、`getAttributeValue`、`find`、`findAll`、`findOne`、`getChildren`、`getParent`、`getSiblings`、`nextElementSibling` 等。
- **CSS 选择器**：配合 `css-select` 支持标准 CSS 选择器（`tag`、`.class`、`#id`、`[attr=val]`、后代/子组合器、`:first-child` 等），覆盖 XIDIAN 的层级定位需求（如 `div.tit ~ ul > li a`）。
- **谓词过滤**：`findAll(test, nodes)` 接受 `(elem) => boolean`，覆盖"按文本内容定位"等自定义需求。
- **明确非目标**：不渲染、不计算样式、**不执行内联 JS / 不跑 `<script>`**。

`elecon:html` 是对 htmlparser2 生态的**薄封装与再导出**，不自造 API，adapter 开发者可直接参考 htmlparser2/domutils/css-select 文档。

### 2.3 容错与确定性（双跑一致性的新承重点）

- **零漂移保证**：两端加载**同一份** htmlparser2 bundle 源码 → 同一输入必然同一输出，容错行为天然一致（不存在"两个不同实现对 tag-soup 行为不同"的问题）。
- htmlparser2 的 tag-soup 容错策略（未闭合标签、可选闭合的 `li`/`p`、void 元素等）是成熟且稳定的（npm 周下载 7500 万+，edge case 经多年社区验证）。
- **版本锁定**：htmlparser2 版本一经选定，**升级等同契约改动**（红线 #6），须走 ADR / 版本化，不得随手升——任何容错行为变更都可能导致双跑 golden 飘。
- **确定性硬要求不变**：同一输入两端必须同一输出（golden）。双跑测试覆盖 htmlparser2 的容错矩阵。

### 2.4 选型：htmlparser2 生态（MIT，纯 JS）

| 取向 | 取 | 舍 |
|---|---|---|
| **htmlparser2 + domutils + css-select（决定）** | 成熟（npm 周下载 7500 万+）、edge case 覆盖充分、CSS 选择器开箱即用、MIT 许可证零传染、纯 JS 零 Node 依赖（验证过）、esbuild 单文件 bundle 约 59KB | 体积比自写大（59KB vs ~数 KB）；版本升级须按契约流程 |
| 自写极简（~150–250 行） | 体积最小、完全可控 | HTML tag-soup 解析边界情况极多（未闭合/可选闭合/属性引号缺失/CDATA/注释/实体解码…），150 行写不完可靠实现；每遇新学校畸形 HTML 就可能踩新 edge case；自维护成本高 |

**决定取向**：采用 **htmlparser2 生态**。理由：

1. **最大兼容性**：在学校普遍无 JSON feed、HTML 是唯一数据源的现实下，HTML 解析是几乎所有 adapter 的基础能力，必须可靠——不能用"够用就行"的极简解析器赌每所学校的 HTML 都规范。
2. **零漂移**：经 esbuild 打成单文件 ESM bundle，两端加载同一份源码，确定性保证与自写等价。
3. **许可证**：htmlparser2（MIT）、domutils（BSD-2-Clause）、css-select（BSD-2-Clause）、entities（BSD-2-Clause）——全部宽松许可证，红线 #9 无风险。
4. **引擎地板**：htmlparser2 编译产物为 ES5 兼容，使用 `Uint8Array`（QuickJS 支持），无 ES2022+ 特性，无 BigInt。
5. **59KB 可接受**：在 64MiB 内存限额内可忽略；且 HTML 解析是高频基础设施，"为最大兼容性牺牲一部分空间"的权衡合理。

---

## 3. 已知约束与风险（Consequences，草案）

1. **版本锁定是新契约约束。** htmlparser2 版本升级可能改变容错行为 → 双跑 golden 飘。升级须走 ADR/版本化流程（§2.3），CI 双跑闸门拦截。
2. **体积/性能。** 两端 bundle 各加 ~59KB 解析器源码；notice 类小页面无压力，但需对"大页面 × QuickJS"做基准，避免在 UI 端拖慢（background isolate 已兜，ADR-008 §2.2）。
3. **安全：纯解析、无副作用。** htmlparser2 是纯 JS 字符串处理，不碰网络/凭证（非红线 #1）。解析器**无网络能力**即天然不外泄；bundle 前经审计确认无隐藏 I/O。
4. **不解决 JS 挑战 / 反爬。** XJT 类"解析内联 JS 算 answer + 伪造指纹"需在 **fetch 模式**执行握手，**不在本解析器职责内**（见 [`adr_009`](./adr_009_fetch_credential.md) 的 HTML/多步贴合说明）。
5. **上游依赖风险。** htmlparser2 虽成熟但仍是第三方——上游停维或引入破坏性变更时，可 fork 锁定（MIT 许可证允许），代价可控。

---

## 4. 落地清单（待 ADR 接受后，拆成可审查的小 PR）

- **Bundle 构建**：以 esbuild 将 htmlparser2 + domutils + css-select + entities 打为**单文件 ESM bundle**（目标 ES2020，无外部依赖）；产出置于 `adapters/_stdlib/html.bundle.js`，纳入版本管理。
- **SDK**：`contract/adapter-sdk/` 增 `elecon:html` 模块类型声明（re-export htmlparser2/domutils/css-select 的公开 API 子集）。
- **运行时**：两端 `moduleHandler` 注册 `elecon:html` → 加载同一份 bundle 源码（客户端 `flutter_qjs`、服务端 `quickjs-emscripten`）。
- **测试**：bundle 在 QuickJS 中的加载冒烟 + 双跑一致性 + XIDIAN `notice.list` 端到端 golden + 畸形 HTML 容错矩阵。
- **文档**：adapter 编写指南补"HTML 源 adapter"小节 + `elecon:html` API 参考（指向 htmlparser2 官方文档）。
- **首例落地**：XIDIAN `notice.list`（parser 模式）——已在本地 spike 中验证 API 形态与可行性。
