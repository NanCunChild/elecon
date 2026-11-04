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

西电本科和研究生包使用原生输入后在官方 IDS 表单写入账号密码，触发学校自身按钮；不自行绕过滑块/验证码或引入实验 PDA 密码协议。错误只从指定 IDS 错误区域和认证路径判断；检测到 MFA/验证码后保留当前官方页面供用户完成，仍只提交一次密码。必须经 IDS 与教务只读接口验证后才保存输入。真实学校 DOM、滑块和账号验收仍独立于合成测试。

## 密码、验证码与恢复的取舍（2026-11-04）

保留原生账号密码输入与保存选项，官方 WebView 承担密码加密、滑块和 MFA。用户可以直接选择网页登录，也可输入一次密码后在同一个官方页面完成挑战。此方式不用随应用分发 OCR 模型权重，也不会把验证码或账号材料交给公共 AI 服务。验证码的形态决定识别方案，不能把“大部分都需要 AI”当成现有实现的前提。

简单、确定格式的文字算式可以由学校脚本解析；有足够脱敏样本的固定图形才适合评估模板匹配、边缘或像素差。识别置信不足、协议变化、交互滑块和 MFA 都回到用户操作。当前西电生产路径没有足以验证纯算法求解器的固定格式样本，因此本轮不启用猜测求解器，也不引入模型依赖；独立 PDA 实验仍不进入默认登录链。

恢复按失败阶段处理：

| 阶段 | 已实施行为 |
|---|---|
| 页面准备 | 最多 20 次只读就绪检查，间隔 250ms；就绪后仅点击一次学校按钮 |
| 点击后导航 | 丢失返回值的已发点击不重放；仅继续读取官方页状态 |
| 验证码/MFA | 保持原页，清除暂存 Cookie 稳定性证据；在本次 100 秒总期限内允许人工完成，超时报告需要交互 |
| 页面读取 | 连续最多 20 次导航过渡错误，或 3 次浏览器失败；保留原错误阶段，不伪装成密码错误 |
| 密码拒绝/账号禁用 | 仅指定错误区域的明确证据，立即停止，不重试密码 |
| 母票据/业务探测 | 已有 IDS 换子票据一次并验证业务 API；网络、429、权限拒绝、异常数据不触发重新登录 |
| 保存与取消 | 未验证不替换密码；取消或持久化失败不通过重试伪装成功 |

SDK17 优先使用结构化错误 code，旧桥仅接受完整相等的 message；诊断文本包含相似词不授权重试。阶段日志只记录固定阶段名，不记录账号、密码、Cookie、页面 URL 或响应正文。后台自动密码登录仍受隐藏 presenter 未开放的限制；上述人工挑战流程不构成后台执行能力。

本轮通过合成学校页面/凭据回归验证挑战完成、挑战超时、错误分类、单次提交、取消、票据恢复和姓名显示元数据。学校真实 DOM/挑战成功率与人工安全审阅需另行验收。
