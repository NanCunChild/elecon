# 绩点归属重划 · 落地报告（`elecon.grades.list` 1.0 → 1.1）

- **日期**：2026-09-08
- **依据**：[ADR-001](../adr/adr_001_contract.md) §3.5（判据改写）、§8（版本治理）；流水见 [`contract/CHANGELOG.md`](../../contract/CHANGELOG.md)
- **性质**：契约 + 客户端本体的同批改动；**本文同时充当 ADR-001 §8 要求的「联动升级文档」**，供无法与本次同批升级的外部仓（`elecon-adapters`）照此跟进。

---

## 1. 改的是业务层的什么

一句话：**「一门课的绩点是多少」和「这学期 GPA 是多少」被拆成了两件事，各自归属不同的层。**

在此之前，ADR-001 §3.5 把两者混称为「派生值」，并整体判给 UI 计算。这在业务上说不通：

- **课程级绩点**是「88 分 → 3.7」这一步换算。**这张换算表是学校自己的规章**——各校不同，同校各院系也可能不同，满分档有 4.0 / 4.3 / 4.5 / 5.0 之分。本体不该、也没有能力知道每所学校的换算表，正如它不该知道每所学校的校历。这是**校本派生**，归 adapter。
- **GPA** 是「把一学期的课加权平均」这一步聚合。这个算法跨校统一，且要参与排序、跨学期对比等本体智能。这是**跨校统一派生**，归本体。

原文其实在同一段里已经给出了正确判据（「跨校统一的派生 → 本体；校本特有的派生 → adapter」），却把 `gradePoint` 判给了 UI——**判据和结论自相矛盾**。本次是把结论纠正到判据上。

### 由此暴露的实际缺陷

契约里的 `gradePoint` 是一个**裸数字**，不带满分档。而 `client/lib/ui/home/home_page.dart` 直接把这些裸数字加权平均，把结果标注为 `GPA`。后果：

- 5.0 制学校会显示一个看起来像 GPA、实际不是任何学校口径的数；
- 跨学期 / 跨数据源混算不同满分档时，结果在数学上无意义；
- 数字是学校给的还是 adapter 推的，消费方无从分辨，出错时无法定位责任层。

## 2. 改了什么

### 契约（`contract/`）

| 位置 | 改动 |
|---|---|
| `schema/grades.list.schema.json` | 列表级新增可选 `gradePointScale`（`4.0`/`4.3`/`4.5`/`5.0`/`other`/`unknown`）；item 级新增可选 `gradePointSource`（`source`/`adapter-derived`/`unknown`）；`gradePoint` 的 description 不再断言「学校来源直接提供」 |
| `capability/registry.json` | `grades.list` 的 `emits.schemaVersion` → `1.1` |
| `generated/{dart,ts}` | codegen 重跑 |

`gradePointSource` 的作用是**把 adapter 的派生从「禁止」变成「可审计」**：adapter 现在可以按校本换算表推算绩点，但必须标注这是推算的，出错时能一眼定位到是学校数据问题还是 adapter 换算表问题。

### 本体（`client/`）

`GradesCard._aggregateGpa()`（`client/lib/ui/home/home_page.dart:247`）——**GPA 展示改为 fail-closed**：

```
gradePointScale 缺失 / 为 unknown / 为 other  →  不展示 GPA
gradePointScale ∈ {4.0, 4.3, 4.5, 5.0}       →  加权平均，并在文案中标注制式
```

展示形态从 `2025-2026-2 · GPA 4.05` 变为 `2025-2026-2 · GPA 4.05（4.3 制）`。课程详情里 `gradePointSource == 'adapter-derived'` 的绩点标注「（推算）」。

> 学校若提供 `gpa.summary`（该 capability 已在 registry 注册、schema 已存在），应优先于本体自算。**目前首页快照尚未接入该 capability**，接入后 `_aggregateGpa()` 让位——这是本次未闭合项，见 §4。

### 模板与夹具

`adapters/_template/{declarative,imperative}` 的 `index.js` 现在声明 `gradePointScale: "4.0"`，并在源站直接给出绩点时标 `gradePointSource: "source"`；两份 `fixtures/grades.list.json` 的 expected 同步；`manifest.json` 的 `emits.schemaVersion` → `1.1`。

## 3. 预期结果

**正向**

1. 学校换算表的知识**下沉到 adapter**，与「adapter 吸收对端混乱、上层保持干净」的第一目标一致；本体不再需要为任何学校的绩点规章负责。
2. **GPA 要么正确，要么不显示**。原先「显示一个尺度不明的数」是最坏形态——用户会拿它做决策却无从察觉它错了。
3. adapter 推算的绩点**可被追溯**，出错时不必在 adapter 与本体之间猜责任。

**代价 / 短期可见的行为变化**

1. **凡是没有声明 `gradePointScale` 的学校，首页 GPA 会消失。** 这是刻意的 fail-closed，不是回归；恢复方式是让对应 adapter 声明尺度（一行）。这也是本次**没有**把客户端改动与契约改动分开两批的原因——分批只会让「GPA 消失」持续更久。
2. `other` / `unknown` 尺度的学校**永远不显示聚合 GPA**。这类学校若需要 GPA，正确出路是接 `gpa.summary` 取学校侧汇总，而不是让本体猜。

**明确不改变的**

- 课程详情里的单科绩点照常展示（不依赖尺度）；
- 未声明新字段的旧数据在 1.1 下仍合法，adapter 不改也不会 schema 校验失败——只是 GPA 不显示。

## 4. 需要的外层联动改动

### 4.1 必做 · 阻塞运行时（外部仓 `elecon-adapters`）

宿主的 output validator **按 `schema + schemaVersion` 精确查表**（`contract/generated/dart/lib/output_validator_registry.dart:9`），且只保留 registry 当前版本（ADR-001 §8「只保护最新版本」）。因此：

| adapter | 现状 | 需改为 |
|---|---|---|
| `school-xidian` | `emits: elecon.grades.list@1.0` | `@1.1` |
| `school-thu` | `emits: elecon.grades.list@1.0` | `@1.1` |

**不改的后果**：静态侧 `tools/` 校验器报 `C2_emits_mismatch` 拒绝签发；运行时 `outputValidatorFor()` 查不到 validator → fail-closed，该 capability 直接不可用。

**同批建议**（非阻塞，但不做则 GPA 不显示）：这两个 adapter 在 `grades.list` 产出里加 `gradePointScale`（西电为 4.3 制，需人工确认；清华需确认），并对来源直接给出的绩点标 `gradePointSource: "source"`。

### 4.2 应做 · 本仓后续切片

| 项 | 位置 | 说明 |
|---|---|---|
| 接入 `gpa.summary` | `client/lib/ui/home/` | capability 已注册、schema 已存在、**客户端零消费**。接入后学校侧汇总优先于本体自算，`other`/`unknown` 尺度的学校也能显示 GPA |
| adapter 换算表落地样例 | `adapters/_template/` | 目前模板只演示 `source`；`adapter-derived` 只在注释里提到，尚无可抄的换算表实现 |

### 4.3 不需要改动

- 服务端 `server/`：grades 走同一 schema，无版本硬编码（`adapters-xidian.grades.imperative.smoke.ts:83` 按 schema 文件名编译，与版本无关）。
- 其他 capability：本次只动 `grades.list`。

## 5. 验证结果

| 门 | 结果 |
|---|---|
| `npm run validate -w tools` | 通过（3 adapter，仅既有 C0 warn） |
| `npm run smoke:all -w tools` | 18/18（含 schema golden 48/48，新增 `gradePointScale` / `gradePointSource` 两个 enum 负例） |
| `npm run smoke:all -w server` | 27/28 —— 唯一失败 `adapters-xidian.card.imperative.smoke.ts`（`capability_missing: card.balance`）**为既有失败**，stash 全部改动后复跑结果一致，与本次无关 |
| `flutter test`（client） | 843 passed（+3：尺度缺失 / 不可聚合 / 已声明三例） |
| `flutter analyze` | No issues found |
