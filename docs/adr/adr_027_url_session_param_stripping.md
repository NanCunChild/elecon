# ADR-027：Broker 跟随重定向时剥离 URL 重写会话参数（`;jsessionid=`）

- **状态**：已接受（2026-07-28）。决策生效；**实现由 AI 起草，落在红线 #1 数据外泄面（Broker 重定向），合并前须人工 + 安全清单复核**（AGENTS.md §1，不得 AI 独自闭环）。
- **日期**：2026-07-28
- **适用范围**：Broker 核心自跟随重定向的纯决策 `decideRedirect`（Dart `client/lib/core/broker/redirect.dart` + TS `server/src/runtime/broker/redirect.ts`），由 `contract/golden/broker/redirect.json` 双端钉一致。
- **依赖**：[`ADR-000`](./adr_000_abstract.md)（可信核心与凭证边界，红线 #1）、[`ADR-009`](./adr_009_fetch_credential.md)（响应脱敏、重定向逐跳、Location 不外泄）。

## 1. 背景与问题

西电 E-Hall（`ehall.xidian.edu.cn`）的业务应用（`jwapp/sys/*`）打开流程是 `GET /appShow?appId=X` → 302 到该应用入口 `.../*default/index.do;jsessionid=<APP_SESSION>`。这里的 `;jsessionid=<...>` 是 Servlet 容器（Tomcat）的 **URL 重写会话标识**：当容器在请求里没看到 JSESSIONID cookie 时，会改用 URL 路径矩阵参数承载会话，并**不下发 `Set-Cookie`**。

Broker 逐跳自跟随重定向时，会照 `Location` 原样跟到带 `;jsessionid=` 的 URL 并停在那里（200）。因为服务器认定客户端走 URL 重写、没建立 cookie 会话，adapter 随后对**干净 URL**（`.../modules/.../*.do`，不带 `;jsessionid=`）发起的数据 POST 便处于"无会话"状态，返回 **403 Forbidden**。真机实测：`grades.list` / `schedule.week` / `classroom.*` 三条能力的数据 POST 全部 403。

逆向 spike `adapters_tests/XIDIAN/ehall/session.py::use_app` 早已发现此陷阱，其处理是**剥掉 `;jsessionid=` 后用干净 URL 再请求一次**，触发容器改用 cookie 会话。

两条独立理由要求把这一步放进 **Broker 核心**、而非 adapter：

1. **红线 #1（凭证边界）**：`;jsessionid=<...>` 是 URL 里的会话令牌，属"带 token 的 URL"这一凭证等价物。adapter 永远不得接触；它会经 `Referer`、日志、浏览历史等侧信道外泄。因此"识别并剥离"必须由核心完成，令牌全程不进入 adapter 面。
2. **正确性**：带 `;jsessionid=` 跟随会命中容器的 URL-rewrite 分支、不下发 cookie 会话，破坏后续同源请求的会话连续性。

（附带发现：现网 `DevLog.network` 会把带 `;jsessionid=` 的请求 URL 写进 release 可见日志——一处会话令牌日志泄漏。本 ADR 的剥离使被跟随 URL 在进入下一跳与日志前即变干净，一并消除该泄漏。）

## 2. 决策

在 `decideRedirect` 解析出绝对 `nextUrl` **之后、`allow` 校验之前**，剥离 URL 重写会话矩阵参数：

- 匹配 `;jsessionid=<value>`（分号前缀的矩阵参数形态，大小写不敏感），value 取到下一个 `/ ? # ;` 或串尾为止，替换为空串。
- 仅剥**矩阵参数**形态；查询串参数 `?jsessionid=` / `&jsessionid=` 语义不同（业务查询字段），**不动**，防过度剥离。
- 剥离后再做 `allow` 校验，使校验作用于干净 URL；`follow.nextUrl` 交回驱动即为干净 URL，无需驱动层二次处理。

正则（两端字面对齐）：`;jsessionid=[^/?#;]*`（TS 用 `/gi` 全局替换；Dart 用 `replaceAll`）。

决策放进 `decideRedirect` 纯函数、由 golden 向量钉死双端一致（新增 3 例：剥离基本形、保留查询串、查询参数不误伤），而非放各语言驱动层——保证 Dart/TS 单一事实源、可回归。

## 3. 范围与非目标

- **范围**：所有学校/所有 adapter 的核心重定向跟随。剥离 URL 重写会话标识是通用安全卫生（会话标识不应出现在 URL），非 ehall 专属 hack。
- **非目标**：不处理响应 body 内的会话令牌（属 ADR-009 已接受的 body 残余风险 / ADR-026 Masker 议题）；不改 cookie 注入、收割或 `allow` 语义；不扩展跟随跳数或状态码集合。
- 当前只剥 `;jsessionid=`（Servlet 生态最常见）。若日后遇到其它容器的 URL 重写标识（如 `;sid=`），按同形正则增补 + 补 golden 向量，无需另立 ADR。

## 4. 备选方案

1. **adapter 侧剥离**：被否。adapter 需先读到带 token 的 URL 才能剥，直接违反红线 #1。
2. **只在驱动层（fetch_proxy / followRedirects）剥、不动纯函数**：被否。会使驱动与 golden 纯决策语义分叉、脱离双端一致回归保护；仅作为本决策落地前的**临时确认实验**用过（已撤除）。
3. **不剥、改为容忍 URL 重写会话**：被否。既留 URL token 外泄面（红线 #1），又要求 adapter 在后续每个请求里回带 `;jsessionid=`（等于让 adapter 持会话令牌，双重违背红线）。

## 5. 影响与实现

| 文件 | 改动 |
|---|---|
| `contract/golden/broker/redirect.json` | +3 向量（剥离 / 保留查询 / 查询参数不误伤） |
| `client/lib/core/broker/redirect.dart` | `decideRedirect` 剥离 `_urlRewrittenSessionParam` |
| `server/src/runtime/broker/redirect.ts` | `decideRedirect` 剥离 `URL_REWRITTEN_SESSION_PARAM` |
| `client/lib/core/broker/fetch_proxy.dart` | 撤除临时驱动层剥离补丁（nextUrl 已在纯函数剥净） |

## 6. 风险与缓解

- **纯 URL 重写、绝不下发 cookie 的服务器**会因此丢会话。此类服务器极罕见，且这类站点本就不该被"cookie 隔离于核心"的架构承载；如遇到，走 ADR 增补例外，不在此默认。
- 正则误伤：已用 golden 覆盖"查询参数 `?jsessionid=` 不剥"，且形态锁定分号矩阵参数。

## 7. 验证

- **真机**：西电 E-Hall `grades.list` / `schedule.week` / `classroom.buildings` / `classroom.available` 数据 POST 由 403 → 200，卡片正常出数（2026-07-28）。
- **回归**：`contract/golden/broker/redirect.json` 17 例 golden 双跑（Dart `broker_redirect_test` + TS `smoke:redirect`）通过；`broker_fetch_proxy_test` 通过。

## 8. 后续

- 合并前人工安全复核（红线 #1 数据外泄面）。
- 关联收尾：ehall 登录入口 URL 已在 `catalog/schools.dart` 修正为经 `ehall/login?service=` 消费 CAS ticket（否则 ehall 从不建会话、收割不到 `ehall-session`）——属 catalog 声明面修复，非本 ADR 范围，但与本故障同一链路，记此备忘。
