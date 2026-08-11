# Probe-001 研究大纲 · OHOS WebView 行为调研

> **目的**：在上真机之前，通过文档/源码/社区调研，摸清 OHOS 上 WebView 相关 API 的现状，为真机验证提供明确的测试点和预期。
> **产出**：每个研究项填结论（文档可确认 / 需真机验证 / 已确认不支持），汇总后决定真机调试的优先级和具体测试用例。

---

## 0. 前置：Flutter-OHOS 生态现状

| 研究项 | 具体问题 |
|---|---|
| Flutter-OHOS SDK 版本 | 当前稳定版是什么？与上游 Flutter 的版本对齐情况？ |
| `flutter_inappwebview` OHOS 支持 | 官方是否声明支持 OHOS？有无 OHOS platform 实现？fork 情况？ |
| `webview_flutter` OHOS 支持 | 官方/社区是否有 OHOS platform 实现？ |
| OHOS 原生 Web 组件 | ArkUI `Web` 组件的能力边界？是否可通过 platform channel 桥接到 Flutter？ |
| 已知限制 / breaking differences | OHOS WebView 与 Android WebView 的已知行为差异汇总 |

---

## 1. 能力 ①：cookie jar 可读（含 HttpOnly）

**核心问题**：登录成功后，宿主能否从 WebView 的 cookie jar 中读取目标域的 session cookie？

| # | 具体行为 | 需调研内容 |
|---|---|---|
| 1.1 | cookie 读取 API 存在性 | OHOS ArkUI `Web` 组件是否暴露 cookie 管理 API？等价于 Android 的 `CookieManager.getCookie(url)` 是什么？ |
| 1.2 | `HttpOnly` cookie 可见性 | API 层面能否读取标记为 `HttpOnly` 的 cookie？（Android 的 `CookieManager` 可以，但某些平台/容器会屏蔽） |
| 1.3 | 按域/路径过滤 | 能否指定域名获取 cookie？还是只能拿全量？跨子域 cookie（如 `.xidian.edu.cn`）是否可见？ |
| 1.4 | cookie 读取时机 | 页面导航完成后立即可读？还是有异步延迟？重定向链中间态的 cookie 是否可捕获？ |
| 1.5 | Flutter 插件层封装 | `flutter_inappwebview` 的 `CookieManager.getCookies()` 在 OHOS 上是否有实现？映射到哪个原生 API？ |

**真机验证要点**：用 CAS 登录流（ids → ehall 重定向链），在 `ehall` 落地后读 cookie jar，确认含 `JSESSIONID`（HttpOnly）。

---

## 2. 能力 ②：导航闭锁可拦（pre-navigation）

**核心问题**：能否在导航**发生前**拦截并否决，实现白名单闭锁？

| # | 具体行为 | 需调研内容 |
|---|---|---|
| 2.1 | 导航拦截回调存在性 | OHOS `Web` 组件是否有 `onLoadIntercept` / `shouldOverrideUrlLoading` 等价回调？ |
| 2.2 | 拦截时机：pre vs post | 回调是在请求发出**前**（可 cancel）还是发出**后**（仅通知）？Android `shouldOverrideUrlLoading` 是 pre-navigation 的。 |
| 2.3 | 重定向链中的拦截 | 302/303 重定向是否也触发拦截回调？还是只有用户主动导航触发？CAS ticket 链全靠 302 跳转。 |
| 2.4 | `about:blank` / `javascript:` 等特殊 scheme | 拦截回调是否覆盖非 http(s) scheme？ |
| 2.5 | 返回值语义 | 返回 `true` = 宿主接管（阻止加载）？还是反过来？ |
| 2.6 | Flutter 插件层封装 | `flutter_inappwebview` 的 `shouldOverrideUrlLoading` 在 OHOS 上是否有实现？ |

**真机验证要点**：设白名单 `ids.xidian.edu.cn` + `ehall.xidian.edu.cn`，发起登录，确认：① CAS ticket 重定向链（302）每一跳都触发回调；② 注入一个越界链接点击，确认被拦截不加载；③ `success.whenUrlMatches` 命中时能触发收割逻辑。

---

## 3. 能力 ③：隔离 profile + 用后销毁

**核心问题**：能否创建隔离的 WebView 会话，互不串 cookie，用后可彻底清除？

| # | 具体行为 | 需调研内容 |
|---|---|---|
| 3.1 | 多实例隔离 | OHOS `Web` 组件多实例之间是否共享 cookie store？还是天然隔离？ |
| 3.2 | 自定义 profile / data directory | 是否支持类似 Android `WebView.setDataDirectorySuffix()` 或 Chromium profile 的概念？ |
| 3.3 | cookie 清除 API | 是否有 `removeAllCookies()` / `removeSessionCookies()` 等价 API？粒度：全量清除 / 按域清除？ |
| 3.4 | 存储清除（localStorage / IndexedDB / cache） | 除 cookie 外，WebStorage / cache 能否按实例清除？ |
| 3.5 | 隐私模式 / incognito | 是否支持类似 `incognito` 模式（内存态，关闭即销毁）？ |
| 3.6 | Flutter 插件层封装 | `flutter_inappwebview` 的 `InAppWebViewSettings.incognito` / `WebView.initialSettings` 在 OHOS 上是否有效？ |

**真机验证要点**：开两个 WebView 实例，一个登录 ids，另一个访问 ids 确认未登录状态（证明隔离）；关闭第一个后再开新实例，确认 cookie 已消失（证明销毁）。

---

## 4. 附加观测项（不作 gate，但影响实现方案）

| # | 行为 | 需调研内容 |
|---|---|---|
| 4.1 | JS 注入时机 | `evaluateJavascript` 在何时可调用？`onPageFinished` 之前能否注入？ |
| 4.2 | JS 世界隔离 | 注入的 JS 是否与页面 JS 共享 window？有无类似 `createWebMessageChannel` 的隔离通信？ |
| 4.3 | UserAgent 自定义 | 能否设置自定义 UA？某些学校 CAS 会检测 UA。 |
| 4.4 | SSL 证书错误处理 | 能否捕获/忽略证书错误？（部分学校内网证书可能有问题） |
| 4.5 | 性能与内存 | OHOS WebView 的内存占用 baseline；多实例场景下是否有限制？ |

---

## 5. 研究信息源（建议优先级）

1. **HarmonyOS 官方文档**：ArkUI `Web` 组件 API Reference（重点看 `WebviewController`、`WebCookieManager`、`onLoadIntercept`）
2. **flutter_inappwebview 仓库**：搜索 OHOS/OpenHarmony 相关 issue、PR、platform 目录
3. **webview_flutter 仓库**：同上
4. **OpenHarmony 源码**：`web_webview` 组件的 native 实现
5. **华为开发者论坛 / Stack Overflow**：OHOS WebView cookie 读取、导航拦截的实践帖
6. **Flutter-OHOS SDK 文档**：platform channel 与原生组件桥接方式

---

## 6. 研究产出格式

每项填写：

- **结论**：`✅ 文档确认可行` / `⚠️ 文档模糊，需真机验证` / `❌ 文档确认不支持` / `❓ 无文档，需真机验证`
- **依据**：文档链接 / 源码位置 / 社区帖子
- **真机测试用例**（如需）：一句话描述验证步骤

文档调研完成后，汇总为"真机验证清单"——只把 `⚠️` 和 `❓` 项带上华为云真机。
