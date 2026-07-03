# WebView 登录收割 + XIDIAN fetch 取数可行性

> 状态：实施前参考清单。依据 ADR-012 / ADR-015 / ADR-016。本文不新增契约；若实现中发现需要扩 `contract/`，须先开 ADR。
> 边界：本文覆盖 Android / iOS 主线。OHOS 仍按 probe 线路等待 fork / 真机验证，不阻塞主线。

## 1. 当前结论

- Android / iOS 可以先落 WebView 登录收割；平台 SDK 本身不是阻塞项。
- XIDIAN 私密能力不能让 adapter 自己登录；登录、ticket、openid、cookie 收割必须在可信核心内完成。
- fetch 直接取数可行，但只适合 official adapter，并依赖 WebView 收割得到的 session 已进入 `CredentialStore`。
- XIDIAN 首批适合落：`grades.list`、`schedule.week`。一卡通次之；水电最后。

## 2. WebView 登录收割最小闭环

### 2.1 已有前置

- `contract/manifest.schema.json` 已有 `login` 声明：`url` / `navigationAllow` / `success.whenUrlMatches`。
- `credentials` 已能声明 ref、scope、type。
- `tools` 校验器已有 L1-L4：HTTPS、导航白名单、成功 URL、login 无 credentials 告警。
- B5 `decideHarvest` / `harvestInto` 已存在，可复用收割判据 b。
- Dart `CredentialStore` 已有接口，但默认后端仍是 `InMemorySecureStore`。
- `flutter_inappwebview` 已接入；OHOS probe 已提供凭证无关的 WebView API 冒烟入口，但设备侧 S1-S4 与登录收割仍待真机验证。

### 2.2 必须新增的客户端能力

1. `LoginManifestView`：从已验签 manifest 取 `login` + `credentials` + `schoolId`，只含声明，不含凭证值。
2. 核心托管 WebView 页面：加载 `login.url`，不允许 adapter/UI 注入任意脚本。
3. 导航闭锁：每次导航必须命中 `login.navigationAllow`，否则取消。
4. 成功检测：导航命中 `login.success.whenUrlMatches` 后触发收割。
5. Cookie 读取：对 `navigationAllow` 覆盖域读取 WebView cookie jar；cookie 值只进入核心收割路径，不进 UI / adapter / log。
6. 收割接线：把 WebView cookies 转成 B5 可消费的 cookie 视图，调用 `decideHarvest` + `harvestInto` 写入 `CredentialStore`。
7. 会话清理：收割成功、用户取消、失败退出时销毁 WebView 上下文；登出时删除 `CredentialStore` 条目并清理对应 WebView cookie。
8. 真实安全存储：Android Keystore / iOS Keychain 后端。`InMemorySecureStore` 只能保留测试用途。

### 2.3 首批测试要求

- 纯函数测试：URL 命中 `navigationAllow` / `whenUrlMatches`。
- fake WebView driver 测试：允许导航、越界取消、成功触发一次收割。
- fake cookie jar 测试：只有 `credentials` 声明的 cookie 被写入 store；未声明 cookie 丢弃。
- 安全测试：日志与 UI 状态不包含 cookie 值、ticket、openid。
- 人工真机测试：Android / iOS 各跑一次真实 XIDIAN CAS 登录；凭证值只在本地设备，不提交夹具。

## 3. XIDIAN manifest 草样

以下只是落地参考，具体 scope 需按真机收割结果校准。

```json
{
  "adapterId": "school-xidian",
  "schoolId": "xidian",
  "trustTier": "official",
  "mode": "fetch",
  "network": {
    "allow": [
      "https://ehall.xidian.edu.cn/*",
      "https://yjspt.xidian.edu.cn/*",
      "https://v8scan.xidian.edu.cn/*"
    ]
  },
  "login": {
    "url": "https://ids.xidian.edu.cn/authserver/login?service=https://ehall.xidian.edu.cn/new/index.html",
    "navigationAllow": [
      "https://ids.xidian.edu.cn/*",
      "https://ehall.xidian.edu.cn/*"
    ],
    "success": {
      "whenUrlMatches": ["https://ehall.xidian.edu.cn/new/index.html*"]
    }
  },
  "credentials": {
    "ehall-session": {
      "scope": ["https://ehall.xidian.edu.cn/*"],
      "type": "cookie"
    },
    "ids-cas": {
      "scope": ["https://ids.xidian.edu.cn/*"],
      "type": "cookie"
    }
  }
}
```

注意：`ids-cas` 是否需要持久收割取决于续期策略。若首版只需要登录后直接建立 `ehall-session`，可先不持久化 `ids` 域 cookie，减少凭证面。

## 4. fetch 直接取数可行性

### 4.1 可行路径

WebView 登录后，核心已有 session cookie。official fetch adapter 可以调用 `ctx.fetch` 请求 XIDIAN 数据接口：

1. adapter 发起 `ctx.fetch("https://ehall.xidian.edu.cn/...", init)`。
2. Broker 根据 `credentials.scope` 注入 cookie。
3. Broker 自跟随重定向、剥离 `Set-Cookie` / `Location` 等凭证等价物。
4. adapter 只拿到脱敏后的 JSON / HTML body，并归一化到标准 schema。
5. 若 origin 轮换 session，B5 在成功执行后收割声明 cookie。

这条路径对成绩、课表、考试等 E-Hall JSON 接口可行。

### 4.2 能力需求

- `ctx.fetch` 已有：请求、重定向、cookie jar、限额、响应脱敏。
- 需要 `credentials` scope 足够覆盖接口域。
- 需要 adapter 能设置普通业务请求头和 POST body；现有 `RequestInit` 子集已覆盖 method / headers / body。
- 需要参数 schema：成绩、课表已有 params schema；一卡通交易也已有 params schema。
- 需要 fixture 录制/回放：真实返回必须脱敏后入 adapter fixtures。

### 4.3 不能给 adapter 的能力

- 不能读取 cookie jar。
- 不能读取 WebView cookie。
- 不能接触 CAS ticket、openid、`Set-Cookie`、中间 `Location`。
- 不能自己登录或提交账号密码。
- 不能通过 `Cookie` / `Authorization` 自设凭证头；B2 必须继续剥除。

## 5. XIDIAN 各能力判断

| 能力 | 当前资料 | 建议模式 | 落地优先级 | 备注 |
|---|---|---|---|---|
| `notice.list` | 已正式落地 | parser | 已完成 | 公开数据，无凭证 |
| `grades.list` | `adapters_tests/XIDIAN/ehall/scores.py` | fetch 或 parser+核心代取 | 高 | E-Hall JSON，适合首批 |
| `schedule.week` | `ehall/schedule.py` | fetch 或 parser+核心代取 | 高 | 需周次/学期参数归一化 |
| `card.balance` | `card/balance.py` | fetch | 中 | openid 是凭证等价物，必须核心内处理 |
| `card.transactions` | `card/balance.py` | fetch | 中 | 需分页参数与脱敏 fixture |
| `library.loans` | `library/borrow.py` 标注待完成 | 待定 | 低 | 先补逆向与 fixture |
| exams / empty classroom | 已有脚本 | `generic.section` 或新增 ADR | 低 | contract 暂无专用 capability |
| energy | `energy/meter.py` 标注待完成 | campus/headless | 最低 | 校园网内 + AES/sign，复杂度最高 |

## 6. 推荐落地切片

1. Android/iOS WebView 登录收割最小闭环：只支持 manifest 声明、导航闭锁、成功 URL、cookie 收割到内存 store。
2. 替换真实 secure store：Android Keystore / iOS Keychain。未完成前不得录入真实学生凭证。
3. XIDIAN manifest 加 `login` + `credentials`，用测试 ref 和 fake cookie 做校验器/运行时测试。
4. XIDIAN `grades.list` fetch adapter：以脱敏 JSON fixture 先跑通归一化，再接真实登录后的 `ctx.fetch`。
5. XIDIAN `schedule.week` 同步落地。
6. 一卡通单独评审 openid 处理：优先把 openid 视作凭证等价物留在核心，不回交 adapter。
7. iOS release 仍按 ADR-010 复核：若含 fetch/private 能力，必须补隐私说明和 2.5.2 自检；首版可继续 parser-only。

## 7. 需要人工拍板的问题

- WebView 登录是否先只做 Android/iOS，OHOS 继续挂起：建议是。
- 首版是否持久化 `ids-cas`：建议先不持久化，能不用就不用。
- XIDIAN E-Hall 取数采用 fetch adapter 还是 parser+核心代取：若接口请求固定，parser 更薄；若需要 useApp / 动态多步，fetch 更省实现。
- 一卡通 openid 如何建模：若必须跨请求持久使用，应作为 `CredentialEntry` ref，而非 adapter 可见字段。
