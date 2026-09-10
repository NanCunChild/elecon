# ADR-019：`classroom.available` 契约扩面 · 多校空教室最大兼容

- **状态**：**已接受（Accepted）** · **2026-07-22 经人工评审批准**（§6 开放问题全部勾决，见该节）。触碰红线 #6（契约即承重墙）。按 [AGENTS.md](../../AGENTS.md) §1 与 [`feature_workflow.md`](../rules/feature_workflow.md) 慢车道：**schema/registry 落地与 codegen 仍须人工主导的实现 PR**（可与首个 adapter PR 拆分）；AI 起草本 ADR，不得独自闭环契约改动。
- **日期**：2026-07-22
- **依赖**：
  - [`adr_000_abstract.md`](./adr_000_abstract.md)（schema 为承重墙、adapter 只做归一化）
  - [`adr_001_contract.md`](./adr_001_contract.md)（§3.4 全局约定、§8 版本与兼容、§8.1 草案转正约定）
- **被依赖**：（接受后）`contract/schema/params.classroom.available`、`contract/schema/classroom.available`、registry 版本 bump；XIDIAN / 后续 XJT·XJTU·THU·FDU 等 adapter 实现
- **适用范围**：capability `classroom.available` 的 **params + emits** 形状；可选伴生能力 `classroom.buildings`（发现用）。**不含**：UI 交互、校历/节次时刻表宿主能力、凭证/网络白名单（仍属 manifest + ADR-009/013）。

---

## 1. 背景（Context）

### 1.1 现状

`capability/registry.json` 已注册：

| 面 | schema | 当前形状（摘要） |
|---|---|---|
| params | `elecon.params.classroom.available@1.0` | 可选：`date` / `start` / `end` / `campus` |
| emits | `elecon.classroom.available@1.0` | 可选顶栏 `date`/`start`/`end`；`items[]` 必填 `building`+`room`，可选 `campus`/`capacity`/`equipment`/`occupied`/`status∈{available,occupied,unknown}` |

该形状**无法干净落地**已有探针（尤其 XIDIAN）：缺 **教学楼 code**、**学期**、**节次轴**、**分节占用**；`start`/`end` 语义未钉死（壁钟 vs 节次 vs 自由串）。

红线 #6 + ADR-001 §8：改契约须先 ADR，默认向后兼容。

### 1.2 多校探针差异（兼容性矩阵）

依据 `adapters_tests/` 与既有逆向（**非契约**，仅作形状驱动证据；XJT/XJTU 空教室探针尚未齐，表内标「预留」）：

| 学校 | 数据源特征 | 查询轴 | 返回粒度 | 对契约的压力 |
|---|---|---|---|---|
| **XIDIAN** | ehall `kxjas`；`ehall-session`；先 `useApp` | **楼栋 code** + **日历日** + 学期段；占用按 **11 节** 布尔 | 楼内教室列表 + 每教室 `sections[11]` | 必须：`buildingId`、`date`/`term`、分节 `sections`；壁钟 `start`/`end` 非源站一等公民 |
| **FDU** | **校内局域网** `http://10.64.x.x`；`daystatus.asp` | **楼栋 code** + **日** | HTML/`status` 数组（日状态） | 必须：`buildingId`+`date`；可能无 term；部分环境仅 campus-relay 可达 |
| **THU** | 教务 + WebVPN；`pk.classroomctrl` | **教室** + **教学周**（`weeknumber`） | 按教室、按周状态 | 必须：`week`、可选 `room`/`roomId`；日历 `date` 需由周换算或由 UI 侧转 |
| **XJT / XJTU** | 探针未闭环（jwapp / ywtb / gmis 等路径待定） | 预留：楼栋/校区/日/周/节次皆可能 | 预留 | **字段宜全可选 + 双时间轴**，避免为西电单校写死 required |
| 其他常见形态 | 有的只有「空闲列表」、无占用细节；有的只给整段 free/busy | 校区 / 楼 / 日 / 时间段 | 列表或矩阵 | `status` 需覆盖 partial；允许省略 `sections` |

### 1.3 问题陈述

1. **过滤键不足**：无法表达「某楼」「某教室」「某教学周」「某学期」。
2. **时间模型单轴**：仅 `start`/`end` 字符串，西电等校以 **节次** 为主；清华以 **周** 为主；壁钟过滤是另一类产品需求。
3. **占用表达过粗**：整室 `occupied: boolean` 无法表达「第 3–4 节占用、其余空」；UI 无法画节次条。
4. **发现（discovery）缺失**：西电/多数校需先列教学楼再查；当前无标准「楼栋列表」capability，UI 只能 hardcode 或塞进 `generic.section`。
5. **向后兼容**：`1.0` 已在 registry；扩面须 MINOR 或明确草案转正路径，禁止静默改义。

---

## 2. 决策（Decision）

### 2.1 版本与治理策略

| 项 | 决策 |
|---|---|
| capability id | **保持** `classroom.available`（不改名、不拆成多个 query capability） |
| 伴生 capability | **新增（可选实现）** `classroom.buildings`：仅 discovery，不替代 query |
| params | `elecon.params.classroom.available` **1.0 → 1.1**（仅**新增可选字段** + 文档化既有字段语义；不删除、不改类型） |
| emits | `elecon.classroom.available` **1.0 → 1.1**（同上：新增可选字段；`status` 枚举**追加** `partial`，属放宽/扩展消费方须容忍未知枚举→按 ADR-001 落到展示兜底，见 §2.5） |
| 草案期 | 接受本 ADR 前：schema 文件**不改**；adapter **不得**依赖 1.1 字段发版。接受后：改 schema + registry `schemaVersion` + codegen；在 ADR-001 §8.1 **补记一条** |
| required | **params 不设 required**（与 `exam.list` 一致）；emits `items[]` 仍要求 **`building` + `room` 同时必填**（展示最小集，**禁止空串**；未知填 `"-"`，见 §2.4）。学校特有 id 一律可选 |

> **为何 `status` 加 `partial` 记 MINOR 而非 MAJOR**：旧消费方若用封闭 switch 且无 `default`，新枚举可能掉分支——ADR-001 §3.4 已要求未知枚举落到 `"unknown"` 语义的展示兜底；本 ADR **强制** UI/宿主对未识别 `status` 按 `unknown` 处理。旧 adapter 不产出 `partial`，旧数据仍合法。

### 2.2 双时间轴（核心）

空教室查询在真实院校里至少有两种「何时」与两种「哪段」：

```
何时（when）——至少提供其一（推荐；不强制 schema required）:
  · date        日历日 YYYY-MM-DD（西电/复旦主轴）
  · week        教学周序号 ≥1（清华主轴；可与 term 联用）
  · term        学期标识（与 schedule.week / exam.list 同形字符串）
  · weekday     1–7（ISO：1=周一…7=周日），在仅有 week、无 date 时辅助；有 date 时可由 date 推导，adapter 可忽略

哪段（window）——可组合；全缺 = 该日/该周「整段可见占用」:
  · 节次轴：sectionStart / sectionEnd   1-based 闭区间
  · 壁钟轴：start / end                 推荐 "HH:mm"（本地校历日墙钟，无时区后缀）
```

**归一化义务（adapter）**：

1. 源站只认节次 → 填 `sections[]`；若调用方给了壁钟 `start`/`end`，adapter **可用**本校时刻表做映射后过滤，**不得**把映射表写进契约；映射失败则返回未过滤全日占用并在 item 上保留 `sections`，由 UI 再滤（或返回 `parse_failed` 仅当源数据本身坏）。
2. 源站只认壁钟/时段 → 可只填 item 级 `occupied`/`status`，**省略** `sections`（缺失 = 该校不提供分节，ADR-001 §3.4）。
3. `date` 与 `week` 同时出现：以 **源站主轴** 为准（西电用 date 推周次；清华用 week）；响应须 **回显** 实际采用的 `date` 和/或 `week`/`term`，避免缓存键歧义。

**与 ADR-001 时间约定的关系**：数据信封（data envelope）/`*At` 仍是 RFC3339 UTC；本域的 `date` 是**日历日**，`start`/`end`/`timeStart`/`timeEnd` 是**墙钟（推荐 `HH:mm`）或节次标签**，与 `schedule.week` 的 slot 先例对齐，**不**强制 `date-time`。

**墙钟时区 `timeZone`（人工评审 2026-07-22 钉死）**：

- emits（及可选 params 回显）增加可选字段 **`timeZone`**：IANA 名，如 `Asia/Shanghai`。
- **全局声明义务在 adapter**：由各校 adapter 据本校校历/源站语境填写；宿主**不得**臆造全局默认时区写进契约，也**不得**在未声明时把墙钟当 UTC 解析。
- 仅产出节次、无墙钟字段时：可省略 `timeZone`。
- 一旦产出 `start`/`end`/`timeStart`/`timeEnd` 任一墙钟字段：adapter **应**同时给出 `timeZone`（缺省时 UI 仅作「本地墙钟展示」、不做跨区换算）。

### 2.3 Params 形状（`elecon.params.classroom.available` @1.1）

```json
{
  "$id": "elecon.params.classroom.available",
  "type": "object",
  "properties": {
    "date":        { "type": "string", "format": "date",
                     "description": "查询日历日 YYYY-MM-DD" },
    "term":        { "type": "string",
                     "description": "学期标识，如 2025-2026-2；省略=当前学期（若源站需要）" },
    "week":        { "type": "integer", "minimum": 1,
                     "description": "教学周序号" },
    "weekday":     { "type": "integer", "minimum": 1, "maximum": 7,
                     "description": "星期 1=周一 … 7=周日" },
    "campus":      { "type": "string",
                     "description": "校区名称或校内 code（校作用域）" },
    "building":    { "type": "string",
                     "description": "教学楼展示名；模糊匹配时 adapter 自定，优先用 buildingId" },
    "buildingId":  { "type": "string",
                     "description": "教学楼校内 id/code（如西电 JXLDM）" },
    "room":        { "type": "string",
                     "description": "教室展示名过滤" },
    "roomId":      { "type": "string",
                     "description": "教室校内 id" },
    "start":       { "type": "string",
                     "description": "窗口起点，推荐 HH:mm（墙钟）" },
    "end":         { "type": "string",
                     "description": "窗口终点，推荐 HH:mm（墙钟）" },
    "timeZone":    { "type": "string",
                     "description": "IANA 时区；调用方可选提示；权威声明在 adapter emits" },
    "sectionStart":{ "type": "integer", "minimum": 1,
                     "description": "节次窗口起点（含），1-based" },
    "sectionEnd":  { "type": "integer", "minimum": 1,
                     "description": "节次窗口终点（含），1-based；须 ≥ sectionStart" },
    "onlyAvailable": { "type": "boolean",
                     "description": "true=只返回在查询窗口内判定为空闲的教室；默认 false=返回楼内对照列表" }
  }
}
```

**`onlyAvailable` 默认 `false`（人工评审确认）**：缺省或未传 = 返回楼内对照列表（含占用室），便于与课表对照；`true` 时 adapter 按 §2.5 过滤为空闲。

**推荐调用组合**（文档约定，非 schema oneOf，以免卡死未建模学校）：

| 模式 | 典型 params | 典型学校 |
|---|---|---|
| A. 楼+日+节次 | `buildingId` + `date` + `sectionStart`/`sectionEnd` | XIDIAN |
| B. 楼+日 | `buildingId` + `date` | FDU、西电「看全日」 |
| C. 教室+教学周 | `roomId` 或 `room` + `week` (+ `term`) | THU |
| D. 校区+日 | `campus` + `date` | 多校宽查（注意结果集膨胀） |
| E. 仅 discovery 后的二次查询 | 先 `classroom.buildings`，再 A/B | UX 标准路径 |

`onlyAvailable=true` 时：adapter 按窗口聚合规则（§2.5）过滤；源站若只支持「全量占用矩阵」，在 adapter 内过滤，**禁止**为此改契约。

### 2.4 Emits 形状（`elecon.classroom.available` @1.1）

```json
{
  "$id": "elecon.classroom.available",
  "type": "object",
  "properties": {
    "date":   { "type": "string", "format": "date" },
    "term":   { "type": "string" },
    "week":   { "type": "integer", "minimum": 1 },
    "weekday":{ "type": "integer", "minimum": 1, "maximum": 7 },
    "start":  { "type": "string" },
    "end":    { "type": "string" },
    "timeZone": { "type": "string",
                  "description": "IANA 时区；adapter 声明；有墙钟字段时应填" },
    "sectionStart": { "type": "integer", "minimum": 1 },
    "sectionEnd":   { "type": "integer", "minimum": 1 },
    "sourceSystem": { "type": "string" },
    "updatedAt":    { "type": "string", "format": "date-time" },
    "items": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["building", "room"],
        "properties": {
          "campus":     { "type": "string" },
          "building":   { "type": "string", "minLength": 1,
                          "description": "教学楼展示名；禁止空串；未知填 \"-\"" },
          "buildingId": { "type": "string" },
          "room":       { "type": "string", "minLength": 1,
                          "description": "教室展示名；禁止空串；未知填 \"-\"" },
          "roomId":     { "type": "string" },
          "floor":      { "type": "string",
                          "description": "楼层，字符串以兼容「B1」「东3」等" },
          "capacity":   { "type": "integer", "minimum": 0 },
          "equipment":  { "type": "array", "items": { "type": "string" } },
          "occupied":   { "type": "boolean",
                          "description": "在查询窗口上的聚合占用；无窗口则「当日是否曾占用」由 adapter 定义并尽量文档化" },
          "status": {
            "type": "string",
            "enum": ["available", "occupied", "partial", "unknown"],
            "description": "available=窗口内全空闲；occupied=窗口内全占用；partial=窗口内部分节次占用；unknown=无法判定"
          },
          "sections": {
            "type": "array",
            "maxItems": 24,
            "description": "分节占用；缺失=该校不提供节次粒度；至多 24 节（schema 上限）；进一步裁剪与可读性由 adapter 负责",
            "items": {
              "type": "object",
              "required": ["index", "occupied"],
              "properties": {
                "index":     { "type": "integer", "minimum": 1, "maximum": 24 },
                "occupied":  { "type": "boolean" },
                "label":     { "type": "string",
                               "description": "展示用，如「第3节」" },
                "timeStart": { "type": "string",
                               "description": "该节墙钟起点，推荐 HH:mm；解释时区见顶栏 timeZone" },
                "timeEnd":   { "type": "string",
                               "description": "该节墙钟终点，推荐 HH:mm" }
              }
            }
          }
        }
      }
    }
  }
}
```

**`building` + `room` 同时必填（人工评审钉死）**：

- 两者均 **required**，且 **禁止空串**（schema `minLength: 1`）。
- 源站缺楼栋名或缺教室名时，对应字段填 **`"-"`**（ASCII hyphen-minus），**不得**省略、不得用空串、不得用全角空白冒充。
- 禁止越界编造不存在的正式楼名/房号；能解析则填真实展示名，不能则 `"-"`。
- 适用 THU 等弱楼栋信息校：`building: "-"` + `room: "<教室展示>"` 合法。

**顶栏回显**：adapter 应把实际生效的 `date`/`term`/`week`/`weekday`/`start`/`end`/`timeZone`/`sectionStart`/`sectionEnd` 能填则填，便于缓存键与 UI 副标题；未使用的轴省略。

### 2.5 聚合规则（`occupied` / `status` vs `sections`）

当存在查询窗口时：

| 条件 | `status` | `occupied` |
|---|---|---|
| 窗口内所有相关节次/时段空闲 | `available` | `false` |
| 窗口内全部占用 | `occupied` | `true` |
| 窗口内有空有占 | `partial` | `true`（偏保守：有占用即 true） |
| 无法映射窗口或源数据残缺 | `unknown` | 省略 `occupied`（缺失≠false） |

无窗口（全日/全周矩阵）：

- 若提供 `sections`：`status=partial` 当且仅当既有 true 又有 false；全 false→`available`；全 true→`occupied`。
- 若无 `sections`：仅设 `status`/`occupied` 能确定的项，其余 `unknown`。

**禁止**：用 `occupied:false` 表示「未知」。

### 2.6 伴生 capability：`classroom.buildings`（discovery）

**动机**：西电 `get_building_list`、清华教室目录、复旦楼栋 code 均需先 discovery；硬编码楼栋违反多校与可热替换。

| 项 | 值 |
|---|---|
| id | `classroom.buildings` |
| params | `elecon.params.classroom.buildings@1.0`：可选 `campus`、`term` |
| emits | `elecon.classroom.buildings@1.0` |

Emits 草案：

```json
{
  "campus": { "type": "string" },
  "items": {
    "type": "array",
    "items": {
      "type": "object",
      "required": ["building"],
      "properties": {
        "campus":     { "type": "string" },
        "building":   { "type": "string" },
        "buildingId": { "type": "string" },
        "roomCount":  { "type": "integer", "minimum": 0 }
      }
    }
  }
}
```

- **非必选实现**：学校若无稳定楼栋列表接口，可不声明该 capability；UI 则允许用户手输 `building`/`buildingId` 或从历史缓存选。
- **不做** `classroom.rooms` 一级 capability（首版）：房间列表通常与占用查询同响应；若未来有校「先列房再查状态」再开 MINOR/新 ADR。

### 2.7 明确不做（非目标）

| 非目标 | 理由 |
|---|---|
| 契约内嵌全校节次时刻表 | 属 `calendar.academic` / 宿主配置；adapter 可选用但不进本 schema required |
| 预约/占座写入 | 另一能力面；本 capability 只读查询 |
| 实时物联网门锁状态 | 超出教务空教室语义 |
| 把 FDU 内网地址写进全局契约 | 网络可达性是 manifest `network.allow` + 传输/中继问题 |
| 为单校把 `buildingId` 设 required | 破坏 THU/宽查与未建模校 |
| `generic.section` 冒充空教室长期方案 | 类型化 UI 与跨校卡片需要稳定域（本 ADR 正为此） |

### 2.8 凭证与网络（提醒，不改既有 ADR）

- XIDIAN：与 grades/schedule/exam 同属 `ehall-session`（见 `xidian_mint_closed_loop_plan`）。
- FDU 局域网：可能需 campus-relay 或仅校网；**公网哑服务不得代持学生会话**（红线 #2/#3）。
- adapter 仍不得看见 cookie/token 值（红线 #1）；本契约只约束归一化 JSON。

---

## 3. 多校映射示例（非规范，供评审）

### 3.1 XIDIAN

```
params: { buildingId: "<JXLDM>", date: "2026-07-22", sectionStart: 3, sectionEnd: 4 }
→ ehall filter JXLDM + RQ + 学期推算
→ items[].sections = [{index:1,occupied}, … {index:11,occupied}]  // 源站 11 节
→ 按 §2.5 由 sections[2..3] 聚合 status/occupied
→ building/room 用展示名；buildingId 回填 JXLDM
```

`classroom.buildings` ← `get_building_list` 的 code/name。

### 3.2 FDU

```
params: { buildingId: "<b>", date: "2026-07-22" }
→ daystatus.asp?b=&day=
→ 将 status 数组映射为 sections[] 或整室 status（以探针字段为准，实现时校准）
```

### 3.3 THU

```
params: { roomId: "<classroom>", week: 12, term: "..." }
→ qyClassroomState
→ building 弱信息：可解析楼栋则填展示名，否则 building: "-"；room 填教室展示名（禁止空串）
```

### 3.4 XJT / XJTU（接受后测试模式，人工评审确认）

- **本 ADR 接受不阻塞**于 XJT/XJTU 空教室探针闭环。
- 探针与首适配在 **Accepted 之后** 进行；实测若需「校区楼群」等新轴，优先 **再加可选字段 MINOR（如 1.2）**，避免 overfit 当前决策。
- 回填映射表至 `docs/reference` 或本文 §3 修订即可，**不**因探针未齐而回退 Accepted。

---

## 4. 版本、registry 与迁移

接受后落地步骤（实现 PR，可与首个 adapter PR 拆分）：

1. 更新 `contract/schema/params.classroom.available.schema.json` → 1.1 字段集；`$comment` 去掉「仅草稿无语义」类表述（若有），写明双时间轴。
2. 更新 `contract/schema/classroom.available.schema.json` → 1.1。
3. 新增 `params.classroom.buildings` + `classroom.buildings` schema。
4. `capability/registry.json`：
   - `classroom.available` 的 params/emits `schemaVersion` → `"1.1"`
   - 注册 `classroom.buildings`
5. 跑 codegen（Dart/TS）与 golden/validator。
6. ADR-001 §8.1 增记本条（MINOR 理由：纯增可选字段 + 枚举扩展 + 新 capability）。
7. 旧 `1.0` 响应仍可被新宿主消费；新字段缺失按 §3.4。发版 adapter 的 manifest 声明 `1.1` 后方可产出 `sections`/`partial` 等。

**不**做 1.0/1.1 双写长期兼容层：宿主按数据信封 `schemaVersion` 解读即可；字段均为可选，1.1 阅读器可读 1.0 数据。

---

## 5. 取舍（Consequences）

**收益**

- 西电空教室可在契约内完整表达节次占用，无需 `generic.section` 歪楼。
- 清华（周）、复旦（日+楼）、未来 XJT 等可用同一 capability，靠可选字段组合，而非每校新 id。
- discovery 与 query 分离，UI 可标准两步，adapter 可只实现其一。
- 双时间轴避免「强制壁钟」或「强制节次」二选一踩坑。

**代价 / 风险**

- params 组合爆炸：UI 与文档须给出推荐模式（§2.3 表）；`tools/` 不做 oneOf 强校验以免误杀。
- `partial` 与聚合规则依赖 adapter 自觉；靠夹具 golden 锁西电等主路径。
- `classroom.buildings` 增加 registry 面；学校不实现时 UI 要降级。
- FDU 内网等可达性仍非 schema 能解决，产品需提示网络环境。
- `building`/`room` 占位 `"-"` 依赖 UI 对「未知」的展示约定；adapter 不得用空串或乱填正式名。
- `timeZone` 由 adapter 声明，漏填时 UI 仅作墙钟展示、不做跨区换算。

---

## 6. 开放问题（评审清单）· **已全部勾决（2026-07-22 人工）**

1. [x] **`building` + `room` 组合必填**：维持两者 required；**禁止空串与越界编造**；未知一律填 **`"-"`**（非「二选一」MAJOR 方案）。
2. [x] **`onlyAvailable` 默认 `false`**：同意（对照列表优先；`true` 才只返回空闲）。
3. [x] **节次数封顶 24**：schema `sections.maxItems: 24`，`index` 最大 24；**进一步缩小与可读性是 adapter 的任务**，契约只防异常膨胀。
4. [x] **`classroom.buildings`**：保持可选伴生 capability；实现可与 `classroom.available` 同 PR 或 follow-up，**不阻塞**本 ADR 接受。
5. [x] **XJT 探针**：采用 **接受后测试** 模式（§3.4）；缺口再开 1.2 MINOR。
6. [x] **墙钟 `timeZone`**：**引入**可选 IANA 字段；**由 adapter 全局声明/填写**，宿主不臆造默认时区（§2.2）。

---

## 7. 落地清单（Accepted 后）

- [x] 本 ADR 状态 → Accepted（2026-07-22 人工评审 + §6 勾决）
- [x] schema ×4（params/emits available 升级 + buildings 新建；含 `timeZone`、`sections.maxItems:24`、`building`/`room` minLength）
- [x] registry + codegen + CI validator
- [x] ADR-001 §8.1 变更记录
- [x] XIDIAN：`classroom.buildings` + `classroom.available` fetch + 脱敏夹具 + smoke（`elecon-adapters`）
- [ ] 文档：`docs/reference` 多校映射表（可从本文 §3 拆出）
- [ ] （非阻塞）THU/FDU/XJT **接受后**探针校准回填映射，必要时 1.2 可选字段

---

## 8. 与 COVERAGE / 路线关系

本 ADR **只解**「空教室契约能表达多校」；不解锁 card openid、library token、energy AES。  
接受并落地 schema 后，XIDIAN adapter 实现 `classroom.*` 进入快车道（不碰核心）；其他校同契约跟进。
