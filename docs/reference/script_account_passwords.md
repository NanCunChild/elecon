# SDK14 保存密码和账号事件

依据 [ADR-072](../adr/adr_072_saved_password_recovery.md)。此页描述已实施的声明、原生输入、受保护保存与事件；隐藏 WebView 尚未开放。

账号作者可声明：

```json
{
  "authentication": {
    "namespace": "school.primary",
    "savedPassword": true,
    "interactiveWeb": true,
    "silentWeb": false
  }
}
```

必须有同包 `login` 入口；SDK13 及以前拒绝新字段。当前 `silentWeb:true` 在安装时拒绝。namespace 为当前学校下的稳定地址，同校受信包可以显式共享；不表示独立最小权限沙箱。

显式登录调用中：

```js
const attempt = await ctx.accounts.password("school", { mode: "manual" });
if (!attempt) return cancelledResult;
// 学校代码用当次 attempt.username/password 登录并验证真实业务接口。
await ctx.accounts.completePassword("school", {
  attemptId: attempt.attemptId,
  outcome: "authenticated"
});
```

原生表单支持输入新值、使用保存值、是否保留和学校网页登录。UI 不读取保存密码；新值只在验证成功并持久化后替换旧值，失败保留旧密码。选择网页登录时，`password` 抛固定 `account_interactive_fallback`，脚本显式转自身网页流程；取消返回 null。未完成或拒绝的保存值尝试阻止自动恢复，用户可手动重试或更新。删除入口只删除保存值，不删除学校会话。

manual 只能由当前前台、声明登录能力及完全匹配的参数调用；普通查询不能冒用。automatic 的持久一次额度和并发门已有实现，但当前没有获准的隐藏认证 presenter，生产调用返回 `account_silent_unavailable`。学校应先用母票据换子票据；母票据明确失效后报告需要登录。不能把普通网络/数据错误解释成坏密码，也不能在循环刷新时重试密码。

`completePassword` 的 outcome 为 authenticated、interactionRequired、credentialsRejected、accountDisabled、unknown。后四者不保存新输入。自动额度在返回保存密码之前持久消耗；重复请求、进程重启和包更新不解除。输入结果和随机 attemptId 仅属于本次身份/来源执行，撤销后不能提交。持久化完成后的身份变化会按实际存储记录做条件回滚，退出时已删除的密码不会被迟到回滚复活。

`ctx.accounts.report(accountId,{status,reason})` 通知核心账号状态，不吞掉业务错误：

| status | reason |
|---|---|
| authenticated | verified |
| signedOut | signedOut |
| expired | primaryExpired、interactionRequired、credentialsRejected、accountDisabled、recoveryBlocked |
| unknown | networkUnknown |

事件不接受任意文本和额外字段；宿主附加批准来源、时间并派生可采取操作。每次最多八个事件，来源/身份撤销后丢弃。`account.session` 只能报告入参指定账号，登录状态检查仍禁密码表单。

西电本科和研究生包使用原生输入后在官方 IDS 表单写入账号密码，触发学校自身按钮；不自行绕过滑块/验证码或引入实验 PDA 密码协议。错误只从指定 IDS 错误区域和认证路径判断；MFA/验证码需要用户选择网页登录完成。必须经 IDS 与教务只读接口验证后才保存输入。真实学校 DOM、滑块和账号验收仍独立于合成测试。
