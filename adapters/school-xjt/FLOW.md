# XJT dean（西安交大教务处）fetch 模式流程 + spike 记录

> Track A spike：第一个 fetch 模式 adapter 的逆向与设计验证。目标数据 = 教务处**公开通知**
> （`notice.list`）。选它是因为它需要 fetch 模式（多步 + JS 反爬挑战），但数据公开、
> **不碰学生凭证**——以最低风险锻炼整条 fetch 链（ADR-009）。

## 1. 实测流程（来自 `fetch.py` 逆向）

```
[1] GET  https://dean.xjtu.edu.cn/                      （passthrough，不注入）
        └─ 命中 JS 挑战页：HTML 内含 `var challengeId="..."` + `var answer=N`
[2] 解析 challengeId / answer（answer 直接给在页面里，无需算 JS）
[3] POST https://dean.xjtu.edu.cn/dynamic_challenge      （passthrough）
        body = { challenge_id, answer, browser_info:{ua,platform,...} }
        └─ 响应 JSON：{ success:true, client_id:"..." }
[4] 把 client_id 作为 cookie 带上（⚠️ 见 §3 设计缺口）
[5] GET  https://dean.xjtu.edu.cn/                       （带 client_id + JSESSIONID cookie）
        └─ 返回真实通知列表 HTML
[6] 解析 div.tz（含「通知公告」）→ li → a[title]（标题/链接）、i（分类）、span（日期）
```

实测 cookie（`pac.txt`，已脱敏）：最终请求带 `client_id=<REDACTED>; JSESSIONID=<REDACTED>`。
两者都是 origin 下发的会话态，**非学生认证**。

## 2. 映射到 ADR-009 fetch 模式

| 流程节点 | ADR-009 机制 |
|---|---|
| GET 挑战页 / POST 挑战 | passthrough（`network.allow` 内、不命中任何 `credentials.scope` → 放行不注入，§2.4） |
| origin 下发的 `JSESSIONID` | per-execution cookie jar 自动持久化 `Set-Cookie`、后续请求自动带（§2.4） |
| HTML 解析 | `elecon:html`（两端零漂移，§2.4 第 1 条 / ADR-011） |
| 反爬挑战由 adapter 解 | official 独占 fetch（§2.4 第 3 条），解析内联值 + 伪造指纹属 fetch 模式职责 |
| client_id（见下） | **⚠️ 缺口** |

**无学生凭证**：`credentials` 块为空 → 全程 passthrough。不需要 ADR-012 凭证存储 / WebView 登录。
client_id / JSESSIONID 是 per-execution jar 的活，执行结束即弃（未被任何 ref 声明 → 不收割入库，§2.4 判据 b）。

## 3. 已修补缺口：client_id 来自 **body**，不是 Set-Cookie

spike（`fetch.py:69-74`）从 POST 的 **JSON 响应体** 读 `client_id`，再 `session.cookies.set(...)`
**手动**设为 cookie。真实浏览器里是页面 JS 把 body 里的 client_id 写进 `document.cookie`。

这曾与 ADR-009 原始模型冲突：
- §2.3：adapter 经 `init.headers` 设的 `Cookie` 头被宿主**无条件剥除** → adapter **不能自己设 cookie**。
- §2.4：per-execution jar 只自动持久化 origin 的 **`Set-Cookie`** → 若 client_id 只在 body、没有 Set-Cookie，**jar 抓不到**，后续请求带不上 → 流程断。

**已确认（2026-06-15 抓包实锤，`adapters_tests/XJT/dean/pac.txt`）**：`POST /dynamic_challenge`
响应**零 `Set-Cookie`**，`client_id` 仅在 JSON body，由页面 JS 自行写 `document.cookie`。
→ ADR-009 已由 rev-3 修补：新增窄通道 `ctx.setEphemeralCookie`（仅 passthrough origin、不覆盖凭证、永不收割、执行即弃）。本 adapter 已使用该接口把 `client_id` 写入 per-execution jar 的 ephemeral 分区，服务端 `npm run smoke:xjt` 覆盖该路径。

## 4. 已采纳的 ADR-009 修订方向

已采纳窄 API 方向，而不是允许 adapter 直接设置 `Cookie` 头：

- adapter 仍不能通过 `init.headers.Cookie` 自设 Cookie；B2 继续无条件剥除。
- adapter 只能调用 `ctx.setEphemeralCookie(name, value, { domain, path? })` 写入 ephemeral 分区。
- Broker 强制四重栅栏：仅 passthrough origin、不覆盖凭证、不收割、执行即弃。
- 红线 #1 不破：这里写回的是 adapter 已从 passthrough body 中读到的反爬 token，不是学生凭证。

## 5. 录制脱敏夹具（需用户在本机/校园网跑，AI 不直连真实校服务器）

需要三份**脱敏后**的固定夹具供回放（ADR-009 §3.6）：
1. `challenge.html` —— 步骤[1] 的挑战页（含 `var challengeId/answer`，可用假值替换真实 id）。
2. `challenge_response.json` + **响应头**（已知零 `Set-Cookie`；夹具用于回放 body-token 路径）。
3. `notice.html` —— 步骤[5] 的真实通知页（删除任何个人化痕迹；通知本身是公开数据）。

脱敏要求（红线 #8）：challengeId / client_id / JSESSIONID 一律替换为假值；不留真实 cookie。

> 抓包建议：用浏览器 DevTools 或 mitmproxy 录一次完整流程，**务必保留 POST 响应的完整 header**
> 以判定 §3。导出后人工脱敏再入 `adapters/school-xjt/fixtures/`。
