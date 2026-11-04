# 登录、账号状态与凭据保存

[返回目录](README.md) · 相关：[官方网页与 DOM](browser.md)、[SDK 调用](sdk-and-host.md)

## 选择登录方式

| 场景 | 接口与入口 |
|---|---|
| 学校有官方登录页、验证码或 MFA | `browser:true`，学校脚本打开可见网页并验证结果 |
| 用户输入账号密码，成功后可保存 | SDK14 的 `accounts[].authentication` 与 `ctx.accounts` |
| 只需补充校区、学号等业务信息 | `ctx.ui.requestInput`，详见[交互](interactions.md) |
| 查询当前账号是否有效 | 同包 `account.session`，不弹窗、不提交密码 |
| 应用内 Hermes/aTrust 登录 | SDK16 声明隧道账号，密码/官方页面由宿主管理 |

保存了凭据不等于服务器认证成功。登录成功须有学校业务接口或可靠源站状态的证据；网络失败是 unknown，不能直接判定密码错误或主账号过期。

## 1. 声明账号和登录按钮

以下是 SDK14+ manifest 片段，示例账号 ID 为 `campus`。`account.session` 同时承担显式登录和只读检查，脚本按 `operation` 区分流程。

```json
{
  "capabilities": [
    { "id": "grades.list", "schema": "elecon.grades.list", "schemaVersion": "1.1" },
    { "id": "account.session", "schema": "elecon.account.session", "schemaVersion": "1.0" }
  ],
  "accounts": [{
    "id": "campus",
    "name": "学校统一认证账号",
    "instructions": "使用学校账号登录；验证码或多因素验证请在官方网页完成。",
    "capabilities": ["grades.list"],
    "login": { "capability": "account.session", "params": { "account": "campus", "operation": "login" } },
    "status": { "capability": "account.session", "params": { "account": "campus", "operation": "status" } },
    "authentication": {
      "namespace": "school.primary",
      "savedPassword": true,
      "interactiveWeb": true,
      "silentWeb": false
    }
  }]
}
```

设置中的“脚本所需账号”显示说明、检查及登录入口，固定到该包和 digest；不会因全局能力覆盖转到另一个包。SDK11 起必须提供 `accounts`，无需账号用 `[]`。纯网页登录可省略 `authentication`，保留 `login/status` 并声明 `browser:true`。使用上例的网页回退也须声明 `browser:true` 及全部认证/业务 origins。

`status` 的参数必须是对应账号与 `operation:"status"`。登录绑定参数必须与实际前台调用一致；工作台临时改参数不等于获得保存密码输入权限。保存密码管理只属于声明的账号登录流程。

## 2. 编写登录流程

下面是**流程骨架**。`authenticateAndVerify`、`visibleWebLoginAndVerify` 和 `checkSessionWithoutInteraction` 必须由学校代码实现，分别完成密码登录后业务验证、可见网页登录后验证、只读状态检查；它们不是 SDK 方法。骨架返回账号标准状态，不能直接拿去连接某个学校。

```js
export const capabilities = {
  async "account.session"(ctx, params = {}) {
    if (params.account !== "campus") throw new Error("input_invalid_request");
    if (params.operation === "status") {
      // 无凭据为 signedOut，明确失效为 expired，网络错误为 unknown。
      // 此分支禁止密码表单、浏览器、扫码和交互登录。
      return checkSessionWithoutInteraction(ctx);
    }
    if (params.operation !== "login") throw new Error("input_invalid_request");

    let attempt;
    try {
      attempt = await ctx.accounts.password("campus", { mode: "manual" });
    } catch (error) {
      if (error.code === "account_interactive_fallback") {
        return visibleWebLoginAndVerify(ctx);
      }
      throw error;
    }
    if (attempt === null) return { status: "unknown" };

    let result;
    try {
      // 一次密码尝试；result.outcome 只能来自本次学校响应和业务验证。
      result = await authenticateAndVerify(ctx, attempt.username, attempt.password);
    } catch (error) {
      await ctx.accounts.completePassword("campus", {
        attemptId: attempt.attemptId, outcome: "unknown"
      });
      throw error;
    }
    await ctx.accounts.completePassword("campus", {
      attemptId: attempt.attemptId, outcome: result.outcome
    });
    return result.state;
  }
};
```

原生密码框允许输入新值、使用保存值、选择是否保留及主动选择学校网页。UI 不读取或回填旧密码。脚本得到本次尝试的 `attemptId/username/password`，仅供当前授权调用使用。

| `completePassword` 的 outcome | 作者应有的证据 | 新密码是否替换旧值 |
|---|---|---|
| `authenticated` | 真实业务核验通过 | 用户选择保留且受保护保存成功后替换 |
| `interactionRequired` | 需要验证码、MFA 或人工交互 | 否 |
| `credentialsRejected` | 学校明确拒绝本次凭据 | 否 |
| `accountDisabled` | 学校明确报告账号停用 | 否 |
| `unknown` | 网络失败或缺乏确认 | 否 |

`completePassword` 只提交状态，不替作者登录或验证。未完成、错误结果和撤销不能发布新密码；保存失败需作为失败处理。自动密码恢复当前没有获准的隐藏 presenter，`mode:"automatic"` 会得到 `account_silent_unavailable`；生产 manifest 必须 `silentWeb:false`。不要用定时刷新反复提交密码。

当前西电实现可参考 [password 登录流程](../../school-scripts/xidian/src/login.js)、[可见网页流程](../../school-scripts/xidian/src/webview_login.js)及[保存密码参考](../reference/script_account_passwords.md)。它们包含学校协议，不是通用核心应复制的代码。

## 3. 状态检查与账号事件

`account.session` 返回以下 JSON 之一，可加源站确认的 `accountId/accountLabel/checkedAt`。`checkedAt` 是 UTC RFC3339，不放 Token 或 Cookie。

```json
{ "status": "authenticated", "accountId": "demo-account", "checkedAt": "2026-11-03T01:00:00Z" }
```

| status | 含义 |
|---|---|
| authenticated | 本次源站验证有效 |
| signedOut | 没有本地会话材料，或已本地退出 |
| expired | 有明确会话失效证据 |
| unknown | 未验证、网络异常或证据不足 |

已声明账号还可发送结构化事件：

```js
await ctx.accounts.report("campus", { status: "expired", reason: "primaryExpired" });
```

合法组合为 authenticated/verified、signedOut/signedOut、unknown/networkUnknown，以及 expired 配 primaryExpired、interactionRequired、credentialsRejected、accountDisabled 或 recoveryBlocked。事件每次最多八个，只能报告声明账号，不能附任意错误正文；事件不会吞掉当前业务错误。

子业务票据失效时，学校脚本应先按既有协议用有效母票据换签并验证业务，不能直接宣布主账号过期。认证恢复后也不能自动重放控制、发送消息或签到。

## 4. 使用凭据库保存 Token

SDK2 起默认 namespace 是稳定脚本 id。以下函数展示学校服务**确认会话有效之后**的写入和随后读取，不代表宿主自动验证 Token。

```js
const SESSION = { namespace: "school.primary" };

async function saveVerifiedSession(ctx, session) {
  // session 由学校登录/验证代码生成；把联动轮换的值放在一条记录。
  await ctx.credentials.set("session", JSON.stringify({
    accessToken: session.accessToken,
    refreshToken: session.refreshToken
  }), {
    ...SESSION,
    type: "token",
    scope: ["https://campus.example.edu/api"],
    expiresAt: session.expiresAt // Unix 毫秒；未知时可明确传 null
  });
}

async function fetchPrivateData(ctx) {
  const saved = await ctx.credentials.get("session", SESSION);
  if (!saved) {
    throw Object.assign(new Error("authentication_required"), { code: "authentication_required" });
  }
  // expired=true 的记录仍可读；需要刷新时由学校协议决定，不能直接沿用。
  if (saved.expired) {
    throw Object.assign(new Error("authentication_required"), { code: "authentication_required" });
  }
  const token = JSON.parse(saved.value).accessToken;
  return ctx.fetch("https://campus.example.edu/api/data", {
    headers: { Authorization: `Bearer ${token}` }, redirect: "manual"
  });
}

async function clearLocalSession(ctx) {
  await ctx.credentials.delete("session", SESSION);
}
```

| API | 返回/含义 |
|---|---|
| `get(key,{namespace?})` | `CredentialRecord` 或 null；含 value、expired、expiresAt 等 |
| `set(key,value,options)` | 字符串值；type、scope、expiresAt 为元数据 |
| `delete(key,{namespace?})` | 删除完整地址的记录 |
| `list()` | 当前学校可用记录，含所有 namespace；不要用于输出调试 |

`scope` 不会自动注入 Cookie/Authorization，也不是同校脚本间的权限隔离。`expiresAt` 是 Unix **毫秒**；更新时省略 type/scope/expiresAt 保留旧元数据，`expiresAt:null` 清除期限。过期记录不自动删除，以便学校脚本刷新。

`set/delete` 返回表示内存已接受；持久化档在调用结束时等待保存，失败为 `credential_persist_failed`。业务输出失败也可能保留已轮换的凭据；不要假定一次能力调用是可回滚事务。H/S/M 档位分别由当前设备后端和用户选择决定，仅内存档不跨重启保存，主密钥不交给脚本。

Profile、学校身份是隔离边界。namespace 只是寻址；同校受信脚本可显式共享，不能指定另一学校。跨脚本共享地址必须明确约定，不能声称增强包有独立最小权限沙箱。

## 5. 保存浏览器 Cookie

浏览器 Cookie 与 `ctx.fetch` 不会自动同步。按实际页面和 API URL 分别采集，保存完整快照：

```js
const targets = [];
for (const url of [
  "https://campus.example.edu/notices",
  "https://campus.example.edu/api/notices"
]) {
  targets.push({ url, cookies: await ctx.browser.cookies(url) });
}
await ctx.credentials.set("browser-cookies", JSON.stringify({ version: 1, targets }), {
  namespace: "campus.session", type: "cookie", scope: targets.map((target) => target.url)
});
```

保留 domain/path/Secure/HttpOnly/SameSite/expiry 和同名 Cookie，不能先按 name 去重，也不能把一个扁平 Cookie 头当完整 jar。`ctx.browser.setCookies(url,cookies)` 用于恢复；构建 HTTP 头时必须按目标 origin/path/domain/期限筛选。可复用现有[浏览器模板的恢复逻辑](../../adapters/_template/trusted/browser/index.js)和 [HTTP 模板的筛选逻辑](../../adapters/_template/trusted/http/index.js)。原生平台缺少属性时不能承诺无损恢复。

## 6. APPTunnel 账号和凭据复用

SDK16 通过 `accounts[].appTunnel` 固定 HTTPS 网关、认证域、节点证书指纹及 password/web 登录方式；相关能力或普通账号通过 `appTunnelAccountId` 声明依赖。缺会话时停止并引导对应账号，禁止直连回退。SDK16 未声明依赖的能力直连，旧 SDK 沿既有路由语义。

普通脚本不能获取宿主管理的隧道密码、SID 或密钥。SDK15 的 `credentialReuse` 是明确同包源账号到指定网关的一次转交关系，目标认证核验后才保存，不把源密码复制给脚本/UI。CAS 网页与本地密码认证域不可混用，学校关系需要实际核实。

具体声明和可打包合成模板见[隧道账号](../reference/script_tunnel_accounts.md)、[凭据复用](../reference/script_credential_reuse.md)。普通 WebView 不能走 APPTunnel；相关浏览器调用会拒绝，不能静默直连。
