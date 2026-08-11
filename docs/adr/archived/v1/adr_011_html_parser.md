# ADR-011：adapter HTML 解析（SDK 内置纯 JS 解析器，零漂移）

- **状态**：已接受（Accepted），分批落地中 本文改动 **adapter SDK 表面（`contract/adapter-sdk/`）+ 两端运行时 moduleHandler**——触及契约与 runtime（红线 #6 契约即承重墙、#10 架构性改动先写 ADR）。**不碰网络/凭证**（非红线 #1）。核心取向经人工审阅接受；落地按 §4 拆批，进度见该节勾选项。
- **日期**：2026-06-12（起草）／2026-06-13（接受 + 首批落地：bundle、两端 runtime、双跑闸门）
- **落地 PR**：[#15](https://github.com/NanCunChild/elecon/pull/15)（`elecon:html` bundle + 服务端/客户端 moduleHandler + XIDIAN `notice.list` + 两端 golden）
- **依赖**：[`adr_001_contract.md`](./adr_001_contract.md)（SDK 类型 / 契约）、[`adr_005_runtime.md`](./adr_005_runtime.md)（服务端 QuickJS-wasm）、[`adr_008_client_runtime.md`](./adr_008_client_runtime.md)（客户端 QuickJS + moduleHandler + engine-floor canary）
- **关联**：[`adr_009_fetch_credential.md`](./adr_009_fetch_credential.md)（imperative 响应体同样复用本解析器，但 HTML 解析本身不依赖 imperative 的存在）
- **被依赖**：HTML 源 adapter（首例 XIDIAN `notice.list`，见 §4）
- **适用范围**：adapter 在 QuickJS 内**解析 HTML** 的能力如何提供。**不含** JSON 解析（已可 `JSON.parse`）、不含 JS 挑战/反爬执行（见 §3.4 与 ADR-009）、不含某校具体 adapter。

---

## 1. 背景（Context）

首批逆向 adapter（XIDIAN / XJT 教务通知公告）暴露一个共性事实：**很多学校的通知公告是 HTML 页面、无 JSON feed**，adapter 必须从 HTML 抓取。而当前运行时**完全没有 HTML 解析能力**：

- `ctx` 只给 `log`/`now`（declarative）或 `fetch`/`log`/`now`（imperative），**无 DOM**（`contract/adapter-sdk/types.d.ts`）。
- 客户端 QuickJS 是 Bellard **2021-03** 版（ADR-008 §3.6），**无 DOM、无 ES2022+、无 BigInt**。
- 现有模板 adapter 全靠 `JSON.parse`——HTML 抓取目前**无支持**。

需求：给 adapter 一个能写"层级定位"（如 XIDIAN 的 `找'通知公告'锚点 → 上溯 div.tit → 取兄弟 ul → 遍历 li`）的 HTML 解析手段，并让两端加载同一份解析器源码，以共享 golden 控制项目已使用语义的漂移（ADR-005/008）。

---

## 2. 决策（Decision）

> 以下取向经人工审阅**接受**。§2.2 的 API 表面已对齐首批落地的实际导出（见 `adapters/_stdlib/src/html.ts`）。

### 2.1 解析器是「QuickJS 内执行的纯 JS 共享模块」，不是 host 原生 `ctx` 函数

- **决定性理由（缩小漂移面）**：若由 host 原生提供（客户端 Dart 一个 HTML 解析器、服务端 Node 一个），两个 tag-soup 实现对**畸形 HTML 的容错行为必然不同**，会扩大双跑差异。
- **形态**：**一份纯 JS 解析器**作为 SDK 模块，经 ADR-008 的 `moduleHandler` 以固定模块名（建议 `elecon:html`）解析；两端加载同一份源码、各自在 QuickJS 内执行，再由共享 golden 验证已使用行为。
- htmlparser2 编译产物为 ES5 兼容（验证通过），**天然遵守引擎地板**（无 ES2022+ / 无 BigInt）；bundle 纳入双跑闸门确保两端加载一致（ADR-008 §3.6 canary）。

### 2.2 API：htmlparser2 + domutils 的 DOM-lite 表面

adapter 通过 `elecon:html` 模块获得以下能力（底层由 htmlparser2 + domutils + css-select + domhandler 提供，源于 `adapters/_stdlib/src/html.ts` 的再导出）：

- **解析入口**：`parseDocument(html: string): Document`（htmlparser2 的 `parseDocument`）；低层 `Parser` 亦导出供流式场景。
- **CSS 选择器**：`selectAll(query, nodes)` / `selectOne(query, nodes)`（css-select），支持标准选择器（`tag`、`.class`、`#id`、`[attr=val]`、后代/子组合器、`:first-child` 等），覆盖 XIDIAN 的层级定位（如 `div.tit ~ ul > li a`）。
- **节点遍历 / 取值**：`domutils` 的 `getText`、`getAttributeValue`、`hasAttrib`、`getName`、`getChildren`、`getParent`、`getSiblings`、`nextElementSibling`、`prevElementSibling`、`textContent`、`innerText` 等。
- **谓词查找**：`find`、`findAll`、`findOne`、`findOneChild`、`existsOne`、`filter`——`findAll(test, nodes)` 接受 `(elem) => boolean`，覆盖"按文本内容定位"等自定义需求（XIDIAN adapter 即以此找"通知公告"锚点）。
- **节点类型守卫 / 构造**：domhandler 的 `Document`、`Element`、`Text`、`Comment`、`isTag`、`isText`、`isCDATA`、`hasChildren`。
- **明确非目标**：不渲染、不计算样式、**不执行内联 JS / 不跑 `<script>`**。

`elecon:html` 是对 htmlparser2 生态的**薄封装与再导出**，不自造 API，adapter 开发者可直接参考 htmlparser2/domutils/css-select 文档。SDK 类型声明（`contract/adapter-sdk/`）随后补（见 §4）。

> **首批实测导入**（XIDIAN `notice.list`，`adapters/school-xidian/index.js`）：
> `import { parseDocument, selectAll, getText, getAttributeValue, nextElementSibling } from "elecon:html";`

### 2.3 容错与确定性（双跑一致性的新承重点）

- **漂移控制**：两端加载**同一份** htmlparser2 bundle 源码，避免维护两套 parser；不同 QuickJS 绑定/版本下的实际行为仍由共享 golden 验证。
- htmlparser2 的 tag-soup 容错策略（未闭合标签、可选闭合的 `li`/`p`、void 元素等）是成熟且稳定的（npm 周下载 7500 万+，edge case 经多年社区验证）。
- **版本锁定**：htmlparser2 版本一经选定，**升级等同契约改动**（红线 #6），须走 ADR / 版本化，不得随手升——任何容错行为变更都可能导致双跑 golden 飘。
- **确定性硬要求不变**：同一输入两端必须同一输出（golden）。双跑测试覆盖 htmlparser2 的容错矩阵。

### 2.4 选型：htmlparser2 生态（MIT，纯 JS）

| 取向 | 取 | 舍 |
|---|---|---|
| **htmlparser2 + domutils + css-select（决定）** | 成熟（npm 周下载 7500 万+）、edge case 覆盖充分、CSS 选择器开箱即用、MIT 许可证零传染、纯 JS 零 Node 依赖（验证过）、esbuild 单文件 ESM bundle | 体积比自写大（实测约 205KB **未压缩**，见下注；vs 自写 ~数 KB）；版本升级须按契约流程 |
| 自写极简（~150–250 行） | 体积最小、完全可控 | HTML tag-soup 解析边界情况极多（未闭合/可选闭合/属性引号缺失/CDATA/注释/实体解码…），150 行写不完可靠实现；每遇新学校畸形 HTML 就可能踩新 edge case；自维护成本高 |

**决定取向**：采用 **htmlparser2 生态**。理由：

1. **最大兼容性**：在学校普遍无 JSON feed、HTML 是唯一数据源的现实下，HTML 解析是几乎所有 adapter 的基础能力，必须可靠——不能用"够用就行"的极简解析器赌每所学校的 HTML 都规范。
2. **共享实现**：经 esbuild 打成单文件 ESM bundle，两端加载同一份源码，并用双跑 golden 约束已使用语义。
3. **许可证**：htmlparser2（MIT）、domutils（BSD-2-Clause）、css-select（BSD-2-Clause）、domhandler（BSD-2-Clause）、entities（BSD-2-Clause）——全部宽松许可证，红线 #9 无风险。
4. **引擎地板**：htmlparser2 编译产物为 ES5 兼容，使用 `Uint8Array`（QuickJS 支持），无 ES2022+ 特性，无 BigInt。
5. **体积可接受**：实测 bundle 约 **205KB（未压缩，`build.mjs` 中 `minify: false`）**——刻意不压缩，使 bundle 在仓库内**可读、可审计**（§3.3 的"无隐藏 I/O"靠肉眼/审计核验，压缩后无从审）。205KB 源码在 64MiB 内存限额内可忽略；HTML 解析是高频基础设施，"为最大兼容性 + 可审计性牺牲一部分空间"的权衡合理。（起草期 59KB 估值系 minify 后口径，与本仓库保留未压缩版的取舍不同。）

---

## 3. 已知约束与风险（Consequences）

1. **版本锁定是新契约约束。** htmlparser2 版本升级可能改变容错行为 → 双跑 golden 飘。升级须走 ADR/版本化流程（§2.3），CI 双跑闸门拦截。
2. **体积/性能。** 两端各加载同一份 ~205KB（未压缩）解析器源码；notice 类小页面无压力，但需对"大页面 × QuickJS"做基准，避免在 UI 端拖慢（background isolate 已兜，ADR-008 §2.2）。
3. **安全：纯解析、无副作用。** htmlparser2 是纯 JS 字符串处理，不碰网络/凭证（非红线 #1）。解析器**无网络能力**即天然不外泄；bundle 前经审计确认无隐藏 I/O。
4. **不解决 JS 挑战 / 反爬。** XJT 类"解析内联 JS 算 answer + 伪造指纹"需在 **imperative requestGraph** 执行握手，**不在本解析器职责内**（见 [`adr_009`](./adr_009_fetch_credential.md) 的 HTML/多步贴合说明）。
5. **上游依赖风险。** htmlparser2 虽成熟但仍是第三方——上游停维或引入破坏性变更时，可 fork 锁定（MIT 许可证允许），代价可控。

---

## 4. 落地清单（拆成可审查的小 PR，落地后删除）

- [x] **Bundle 构建**：以 esbuild 将 htmlparser2 + domutils + css-select + entities + domhandler 打为**单文件 ESM bundle**（目标 ES2020，`minify:false`，无外部依赖）；产出置于 `adapters/_stdlib/html.bundle.js`，纳入版本管理。 — PR #15（`build.mjs` + bundle）
- [x] **运行时（服务端）**：`server/src/runtime/sandbox.ts` 的 `setModuleLoader` 注册 `elecon:html` → 加载同一份 bundle；未知模块名 fail-closed 抛错。 — PR #15
- [x] **运行时（客户端）**：`client/lib/core/adapter_runtime.dart` 的 `moduleHandler` 注册 `elecon:html` → 加载同一份 bundle；未注入时 fail-closed。 — PR #15（本批补全，与服务端对称）
- [x] **测试**：服务端 `sandbox.smoke.ts` XIDIAN golden + schema；客户端 `test/dual_run_test.dart` 同一 bundle、同一夹具 golden 一致 + 未注入 fail-closed。两端分别命中同一 golden，证明覆盖到的行为一致。 — PR #15
- [ ] **SDK 类型声明**：`contract/adapter-sdk/` 增 `elecon:html` 模块 `.d.ts`（re-export §2.2 的公开 API 子集），让 adapter 作者有类型提示。 — **待补**（不阻断运行，仅 DX；adapter 现以 JS 写，无类型门禁）
- [ ] **畸形 HTML 容错矩阵**：把"未闭合 / 可选闭合 li·p / void 元素 / 属性引号缺失 / 实体解码 / 注释·CDATA"做成两端共跑的 golden 套件（§2.3）。当前仅 XIDIAN 真实页 + 模板覆盖，矩阵化待补。 — **待补**
- [ ] **文档**：adapter 编写指南补"HTML 源 adapter"小节 + `elecon:html` API 参考（指向 htmlparser2 官方文档）。 — **待补**
- [x] **首例落地**：XIDIAN `notice.list`（declarative），`adapters/school-xidian/`，含脱敏夹具。 — PR #15
