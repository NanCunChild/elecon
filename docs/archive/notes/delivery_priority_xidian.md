# 优先交付清单：XIDIAN 单校 Android 竖切

> **归档（2026-09-11）**：本文是 2026-07 西电单校竖切交付清单，已停止维护、**不是权威**。当前决策看 `docs/adr/`，
> 执行与签收状态看 [`docs/planning/2026_08_review_remediation.md`](../../planning/2026_08_review_remediation.md)。
> 文内提到的版本号、序号与「仍待做」项以那两处为准。


> 状态：**执行笔记（非 ADR）**。目标是尽快做出「打开 App → 选西电 → 登录 → 看到真数据」的可演示闭环。  
> 约束（已对齐）：只维护自有 adapter → **允许破坏性契约/字段变更**；先 Android，iOS/OHOS 后置；基座硬改（flutterOHOS 等）非本阶段。  
> 关联：`docs/reference/xidian_mint_closed_loop_plan.md`、ADR-000/009/012/016/017/018、`AGENTS.md` 红线。

---

## 0. 原则（砍节奏用）

1. **一条竖切 > 全面正确。** 同一能力在真机上跑通，比多能力半通优先。
2. **公开能力先于登录能力。** 无凭证路径先把「adapter → UI」焊死，再叠登录。
3. **Android only。** 不为 iOS/OHOS 改 API 或加平台分支，除非当前 Android 竖切被阻塞。
4. **自有 adapter 可破。** 字段不够 / 可解耦时直接改 schema + adapter + UI，不必等「社区兼容」；改完同步 codegen 与 golden。
5. **双端降配。** 本阶段以 **client Android 真机** 为准；server 只保 parser/broker golden 不漂，不扩公网带凭证 fetch。
6. **冻结非主线。** 多主题、H 硬件档产品化、AGP 9、第二校、OHOS 探针、新 ADR——默认不做。

---

## 1. 竖切定义（完成标准）

### MVP-A · 无登录真数据（本周级目标）

用户在 **Android debug/release 包** 上：

1. 启动 → 默认/选中「西安电子科技大学」
2. 首页（或调试入口）触发 `notice.list`
3. 经 **已签名 bootstrap 或本地可加载 bundle** 跑 `school-xidian`
4. 卡片展示 **jwc 公开通知真数据**（非 `demo_data`）
5. 失败时有可读错误（load / adapter / 网络），不白屏

**不要求**：登录、mint、成绩课表、公网端点 D 必达（bootstrap 离线即可）。

### MVP-B · 一次登录 + 一门认证能力

在 A 之上：

1. 可见 WebView 登录 IDS → 收割 `ids-cas`（及若同链则 `ehall-session`）
2. `runCapability('grades.list' | 'schedule.week')` 前 `ensureCredential`
3. **fetch** adapter 用 broker 注入 session 取数 → schema → 首页卡片
4. 凭证值不进 UI / 日志默认（DevLog 敏感开关保持 debug-only）

**不要求**：静默 mint 全矩阵、一卡通/图书馆、隐藏 WebView、campus 中继。

### MVP-C · 日常可用（薄）

- 冷启动续用 S 档凭证
- 缺票 / 过期 → 引导重登
- （可选）debug 下 headless mint 换 `ehall-session`，失败降级可见登录
- 下拉刷新、空态/错态可懂

---

## 2. 现状 → 缺口（只列挡竖切的）

| 层 | 已有 | 挡 MVP-A | 挡 MVP-B |
|---|---|---|---|
| adapter | `school-xidian` 仅 **parser** `notice.list` | 分发/加载能否在 App 内命中 | 无 ehall **fetch** capability |
| 分发 | loader + bootstrap 路径代码齐；`kDistributionBaseUrl` 有 | **真实签名 bootstrap/catalog 是否可加载** | 同左 + fetch bundle |
| 会话 | `runCapability` + ensure 骨架 | 首页仍 `loadDemoCampusSnapshot` | ensure ↔ 可见登录 UI 未焊死 |
| 登录 | WebView 收割 + XIDIAN 测试 | — | 真机收割 CASTGC/ehall cookie |
| mint | HeadlessSsoMinter debug 装配 | — | **可后置**；首登同链收 ehall 可先顶住 |
| UI | 卡片会渲染 schema | **未接 `SessionController.runCapability`** | grades/schedule 真数据入口 |
| 平台 | Android 工程可编 | 维持 AGP 8.11.1 | 同左 |

---

## 3. 推荐执行序（严格串行，少并行）

### 阶段 0 · 基线冻结（0.5 天）

- [ ] 钉死本清单为唯一优先级；PR 描述写「服务 MVP-A/B/C 哪条」
- [ ] 构建：不升 AGP 9；不改 qjs/inappwebview 大版本，除非编不过
- [ ] 明确 **破坏性契约** 流程：改 `contract/` → codegen → 更新 xidian adapter + golden + 首页映射（单 PR 可纵向打穿）

### 阶段 1 · MVP-A：公开通知竖切（最高优先）

目标：demo 下线，真 `notice.list` 上首页。

| # | 任务 | 完成判据 | 备注 |
|---|---|---|---|
| A1 | **bootstrap 可加载 school-xidian** | 冷启动无网也能 `loadAdapter('school-xidian')` 成功，或失败原因是运维配置而非代码洞 | 签名/pin 人工过一遍；可先用已有 `assets/bootstrap` 扩包 |
| A2 | 核心代取 parser 请求 | 宿主对 manifest `requests` 拉 HTML，脱敏后喂 parser | 无凭证；红线 #5 仍是纯解析器 |
| A3 | `SessionController` / 薄 facade 出「首页快照」 | `Future<CampusSnapshot>` 内调 `runCapability('notice.list')` 填 notices | 其它字段可空 · **已接** `campus_snapshot_loader` + 资产 `html.bundle.js` |
| A4 | `MainShell` / `EleconHomePage` 接真 `loadSnapshot` | 去掉默认 demo 路径（debug 可留开关） | 破坏 UI 约定可接受 · **已接**（`kForceDemoHomeSnapshot`） |
| A5 | Android 真机/模拟器演示 | 能刷出 jwc 列表；记录一次成功日志截图 | **本阶段完成门** |

**故意不做**：grades、登录、mint、第二校、server 新能力。

### 阶段 2 · MVP-B：登录 + 一门 ehall 能力

先选 **一个** 能力（建议顺序）：

1. **`schedule.week`**（首页视觉强、演示好）  
2. 或 **`grades.list`**（逆向/夹具更熟则选它）

不要两个一起上。

| # | 任务 | 完成判据 | 备注 |
|---|---|---|---|
| B1 | 从 `adapters_tests/XIDIAN/ehall` 固化 **一条** 请求链 | 本地脚本用真实 cookie 能打出稳定 JSON | 脱敏进 fixtures；无 PII |
| B2 | `school-xidian` 升 **fetch**（或同 id 多 capability） | manifest 声明 allow + `ehall-session`；capability 产出贴 schema | **允许改 schema** 若字段不合适 |
| B3 | 签名 bundle 进 bootstrap / 测试分发 | App 内 load 到含新 capability 的包 | 与 A1 同路径 |
| B4 | 可见登录 → store 有 `ehall-session` 或 `ids-cas` | 真机走通收割 | 首登 service 指向 ehall，尽量一次拿到 session |
| B5 | `ensureCredential` 焊到 `runCapability` 前 | 无票 → 弹登录；有票 → 跑 adapter | mint 失败则直接 visible（可先不做 L1） |
| B6 | 首页卡片吃真 schedule/grades | 下拉刷新可复现 | **本阶段完成门** |

**静默 mint（HeadlessSsoMinter）**：仅当「每次要数据都要重开 WebView」不可接受时再开；**不阻塞 B 完成门**。

### 阶段 3 · MVP-C：可留着用的薄壳

| # | 任务 | 完成判据 |
|---|---|---|
| C1 | 冷启动 S 档续票 + 选校记忆 | 杀进程再开仍已登录态（在 cookie 未过期时） |
| C2 | 401/空 session → needVisibleLogin | 用户可一键重登，不卡死 |
| C3 | （可选）debug mint `ehall-session` | 有母票时无 WebView 能刷课表/成绩 |
| C4 | 错态文案 | load / auth / adapter / network 可区分 |

然后再考虑：第二 capability、card、library、公网端点 D 正式部署。

---

## 4. 契约 / adapter 破坏性更新策略（本项目优势）

因为 adapter 自维护、无外部贡献冻结：

| 情况 | 做法 |
|---|---|
| schema 字段名别扭 / 缺展示字段 | **直接改** `contract/schema` + codegen + xidian + UI；一记版本 bump |
| ehall 原始 JSON 难映射 | 先在 adapter 内归一到「够首页用」的最小字段集；不必一次对齐完美教务语义 |
| parser 与 fetch 同 bundle 过重 | 可暂时 **一个 adapter 多 capability**；勿拆多包增加分发面 |
| 旧 golden 挡路 | 更新 golden，不保留无用兼容分支 |

唯一红线仍守：

- 凭证不进 adapter 可见面、不进提交夹具  
- 改 `contract/` 若动信任/注入语义 → 先想是否要 ADR；**纯展示字段**可走快车道（见 `docs/rules/feature_workflow.md`）

---

## 5. 明确冻结（直到 MVP-B 完成门）

| 冻结项 | 原因 |
|---|---|
| 第二校（xjt 等）| 分散适配与登录矩阵 |
| iOS / OHOS 功能开发 | 平台税；Android 通后再谈 |
| flutterOHOS / 自改引擎基座 | 仅当 OHOS 成为主阻塞时再开 |
| AGP 9 / 全局 Java 大挪 | 无产品收益 |
| server 公网带凭证 fetch | 竖切不需要 |
| 水电 energy / 盲签名 | ADR-017 盲区，v1 不做 |
| H 硬件档打磨、多主题深化 | 非闭环 |
| 新 ADR（除非红线被逼） | 文档税 |

---

## 6. 建议的 PR 切片（小步、可审）

```
PR-A1  bootstrap 含 school-xidian 可 load（含签名物料/脚本，人工过签）
PR-A2  首页 loadSnapshot → runCapability(notice.list) + 去 demo 默认
PR-B1  ehall 单能力 fetch adapter + fixtures（无 UI）
PR-B2  登录 ensure 焊死 + 首页接 schedule/grades
PR-C1  续票 / 重登 / 错态
```

安全敏感（收割、inject、签名 bootstrap）：PR 描述勾 ADR + 红线，**人工合**。

---

## 7. 验证清单（每阶段出门）

**MVP-A**

- [ ] `flutter test` 相关 loader/adapter 单测不红  
- [ ] Android：无登录刷出通知列表  
- [ ] 断网：bootstrap 路径仍可解析（或明确提示需网拉 HTML——parser 代取需网时写清）

**MVP-B**

- [ ] 真机登录后 capability 成功 ≥1 次  
- [ ] DevLog 默认无 cookie/token 明文  
- [ ] 登出后能力变 auth 失败并引导登录  

**MVP-C**

- [ ] 杀进程重进仍可用（未过期时）  
- [ ] 人为删票 / 过期后可恢复  

---

## 8. 一句话路线图

```
A: 签名包可载 + notice 真数据上首页
        ↓
B: 登录一次 + 一个 ehall 能力真数据上首页
        ↓
C: 续票/重登好用
        ↓
   再开：第二能力 / mint 静默 / 分发端点 / 他校 / iOS·OHOS
```

**当前下一刀：只做 A1→A5，不做登录。**
