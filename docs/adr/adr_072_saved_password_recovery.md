# ADR-072 · 声明式保存密码、验证提交与有界账号恢复

- 日期：2026-11-03
- 状态：Accepted（按所有者继续实现授权；真实学校及人工安全审阅独立验收）
- 承接：ADR-068、070；SDK14 新接口，旧包不改变。

## 声明与身份

`accounts[].authentication` 声明 `{namespace,savedPassword:true,interactiveWeb,silentWeb}`。namespace 是同校寻址，不是隔离沙箱；账号必须有同包登录入口。保存密码仅在当前 Profile/学校的 H/S/M 凭据后端保存，宿主凭据库和密钥不传给 UI。UI 只取得账号名、是否保存及阻断原因，输入框只处理本次新输入；脚本通过本次执行的 `ctx.accounts` 获取已声明账号的密码。

`ctx.accounts.password(accountId,{mode:'manual'|'automatic'})` 返回 null（用户取消）或 `{attemptId,username,password}`。manual 仅允许当前前台、同包声明的登录入口和完全匹配的登录参数；普通业务刷新无法通过设置 mode 绕过自动额度。宿主固定输入模板让用户选择使用保存值、更新新值、是否保留；不把保存密码回填给 UI。用户选网页登录时抛固定 `account_interactive_fallback` 供学校脚本显式转网页流程；取消仍返回 null。automatic 不弹框，仅在声明 silentWeb、存在保存值和宿主隐藏认证 presenter 可用时允许。

`completePassword(accountId,{attemptId,outcome})` 的 outcome 为 authenticated / interactionRequired / credentialsRejected / accountDisabled / unknown。只有学校脚本完成实际业务探测，才可提交 authenticated。attemptId 是随机的一次执行对象，绑定当前学校、批准 digest、账号 namespace、凭据修订和取消代际；不能从另一调用复用。

## 持久恢复门

自动取密码之前先将该修订的自动额度标为已消耗并持久化；持久化失败不返回密码。进程重启、并发查询、更新包、普通刷新均不恢复额度。一次成功自动恢复后额度同样保持消耗，下一次需明确手动登录或更新凭据；这个保守规则避免服务探测误判形成循环。手动使用保存值也在发起之前阻断自动尝试，成功后才重新允许后续一次自动恢复。

新密码先存在本次调用内存，成功验证并持久化才替换旧值；失败或取消不覆盖旧密码。保存失败或 flush 期间身份撤销，按后端实际记录做条件回滚并再次持久化；并发退出已删除的值不复活。不能报告登录保存成功。未完成的自动尝试保持阻断；失败原因不会被推断为密码更改或账户禁用。删除保存密码只删除此账号的密码/恢复记录，不伪装为服务端退出。

宿主执行队列按身份串行，恢复门在持久化之前同步占位，因此并发调用至多一个获得该修订。学校脚本仍先用母票据换取子票据；仅有明确母票据失效证据时才请求密码。只读业务恢复后最多重查一次；所有副作用禁止自动重放。

## 结构化事件

`ctx.accounts.report(accountId,{status,reason})` 仅允许声明账号和当前账号用途。status 沿用 authenticated / signedOut / expired / unknown；reason 固定为 verified / signedOut / primaryExpired / interactionRequired / credentialsRejected / accountDisabled / recoveryBlocked / networkUnknown。宿主派生可采取操作，附加来源、digest、时间，并按当前执行代际接收事件。事件不能带任意正文、Cookie、密码或异常；迟到事件被撤销，业务错误仍终止自身调用。

## 浏览器与迁移

保存密码登录由学校脚本操作学校页面 DOM，宿主不识别学校表单/算法。可见网页登录是显式 fallback。隐藏认证必须复用浏览器租约、TLS、取消与网络边界，并验证活跃自动 attempt；APPTunnel 未接 WebView 时继续拒绝。隐藏 presenter 或其网络覆盖未就绪时，包不得声明 `silentWeb:true`，自动恢复返回固定不可用/需交互；不能用屏外可见页假称完成隐形恢复。

SDK14 同步包 schema、Dart/TS SDK、打包校验和测试；SDK13 及以下拒绝新声明。测试使用合成凭据，覆盖持久化失败、重启阻断、失败保留旧、过期 attempt、来源/身份撤销、非登录入口 manual 拒绝、事件过滤与真实 QuickJS。
