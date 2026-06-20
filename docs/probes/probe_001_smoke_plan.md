# Probe-001 真机执行计划 · 阶段一：工具链冒烟（凭证无关）

> **类型**：真机执行计划（[`probe_001_ohos_webview_harvest.md`](probe_001_ohos_webview_harvest.md) 的分阶段落地，先于完整三能力探针）。
> **决策依据**：桌面调研（[`probe_001_research_findings.md`](probe_001_research_findings.md)）已把 ① cookie/HttpOnly 可读、② 导航闭锁可拦定为「文档级确认」，选型锁定 `flutter_inappwebview_ohos`；真机唯一未决的是 **③ 隔离 profile + 残留清除时序**。
> **本阶段范围**：**仅验证工具链可用** —— OHOS 嵌入能生成、`flutter_inappwebview_ohos` 能 build/跑、WebView 能加载页面、cookie 能从宿主侧读出、`shouldOverrideUrlLoading` 能触发。**全程凭证无关**（不碰 CAS 登录、不收割 session）。
> **🔒 边界**：本阶段刻意不触红线 #1。完整 ③ 验收（XIDIAN IDS CAS 登录 + session 收割）是**下一阶段、人工主导**（AGENTS §1：AI 不得独自闭环），不在本计划内。

关联：issue #65 · ADR-016 §2.4 · [`probe_001_ohos_webview_harvest.md`](probe_001_ohos_webview_harvest.md)

---

## 0. 为什么先冒烟（不直接写完整探针）

- **`client/ohos/` 尚不存在**：OHOS 嵌入从未生成过，需先 `flutter create --platforms ohos` 落地平台目录。
- **Flutter 版本分叉**：主线/CI 锁 **3.44.1（官方）**；Flutter-OHOS 在 **~3.22.x-ohos**。OHOS 构建须切到**独立 FVM SDK**，官方 3.44.1 **不能** build OHOS。→ OHOS 探针与主线 `flutter test` 闸门**不共享 SDK**，须隔离对待（见 §4）。
- 在工具链未证可 build 前写完整三能力探针 = 可能整块返工。冒烟通过 = build/加载/读 cookie/拦导航四件事都成立，再投入完整探针成本最低。

---

## 1. 前置：环境搭建清单（可复现）

> 目标平台为 OHOS 真机（你已就绪）。以下命令版本号以**执行时锁定的实际值**为准，锁定后回填本节。

- [ ] **FVM 装独立 OHOS SDK**：用 OpenHarmony-SIG 的 Flutter-OHOS 分支（如 `3.22.0-ohos` 系），与官方 3.44.1 并存。平时主线用官方版保持纯净，仅打/跑 OHOS 时 `fvm use` 切 ohos SDK（README「HarmonyOS」节既定策略）。
- [ ] **DevEco / OHOS SDK + 签名**：装 DevEco Studio 配套 OHOS SDK；配好真机调试证书（HarmonyOS 应用签名），`hdc list targets` 能看到真机。
- [ ] **生成 OHOS 嵌入**：在 `client/` 下用 ohos-fork 的 flutter `flutter create --platforms ohos .`，生成 `client/ohos/`。补 `client/ohos/README`（README 已引用但缺）。
- [ ] **加 WebView 依赖**：`flutter_inappwebview`（6.x）+ OHOS 移植 `flutter_inappwebview_ohos`，**经 `dependency_overrides` 注入**（鸿蒙特有依赖用 override 替换，README 既定）。锁定实际版本后回填。
- [ ] **冒烟可跑**：`fvm flutter run -d <ohos-device>` 能把空 app 推上真机。

**dependency_overrides 草样**（版本待锁定后回填，勿照抄版本号）：
```yaml
# client/pubspec.yaml —— 仅 OHOS 构建链路使用
dependencies:
  flutter_inappwebview: ^6.0.0
dependency_overrides:
  flutter_inappwebview_ohos:
    git:
      url: <OpenHarmony-SIG flutter_inappwebview_ohos 仓>
      ref: <锁定 tag/commit>
```

---

## 2. 冒烟标的（凭证无关）

用**公开、无登录**的页面，不用任何学校鉴权页：

- 首选 XIDIAN 公开通知页（与现有 `notice.list` 同域、零凭证），或任一稳定公开页（如 `example.com`）。
- 不输入任何账号口令；不触发 CAS；不读取/落盘任何 session/JSESSIONID 级凭证。冒烟读的 cookie 须是页面公开下发的非敏感 cookie。

---

## 3. 验收标准（四项，全部凭证无关）

| # | 验收项 | 判据 | 对应完整探针能力 |
|---|---|---|---|
| S1 | **WebView 能加载** | 真机上 `InAppWebView` 加载标的页、`onLoadStop` 触发、可见渲染（非白屏）。 | 选型可用性（`flutter_inappwebview_ohos` 真能跑） |
| S2 | **cookie 宿主可读** | `onLoadStop`（≥`onPageFinished`）后，`CookieManager.getCookies(url)` 读出**非空**、含标的页公开 cookie。 | ①（机制连通；HttpOnly 穿透留完整探针验） |
| S3 | **导航回调触发** | 点站内链接/触发一次跳转 → `shouldOverrideUrlLoading` 被调用、能拿到目标 URL、`return true` 能拦下。 | ②（锚点 `onOverrideUrlLoading` 在真机确触发） |
| S4 | **incognito 实例可建** | 以 `incognito: true` 建实例能正常加载、`onDisAppear`/销毁不崩。 | ③ 的**前置**（隔离/残留时序的强度仍留完整探针真机压测） |

> S2/S3 时序坑（来自调研）：cookie 必须等 `onLoadStop`/`onPageFinished` 后读（`Set-Cookie` 走内核异步队列，过早读空串）；UA/JS 注入须在 `onControllerAttached` 且 `src` 仍空时设。冒烟即顺带验证这些锚点在真机的真实时序。

---

## 4. 产物与 CI 处置

- **代码落点**：建议 `client/` 下独立 probe 入口（如 `client/tool/ohos_probe/` 或 `--dart-define` 切换的 debug-only 屏），**不进 release**（与红线 #4/#5 的 debug-only 例外同范式：探针/侧载路径编译期从发版剔除）。
- **不进主线 CI**：OHOS 在分叉 SDK（§0），主线 `flutter test`（官方 3.44.1）跑不了 OHOS；冒烟为**真机手动门**，证据按 [`probe_001_ohos_webview_harvest.md`](probe_001_ohos_webview_harvest.md) 的证据格式留档，不做自动闸门。
- **证据**：S1–S4 各留一条日志/截图（cookie 值打码，红线 #8），回填本文。

---

## 5. 冒烟通过后 → 完整探针（下一阶段，人工主导）

S1–S4 全绿 = 工具链 + 选型在 OHOS 真机坐实，于是进完整探针：
- ① HttpOnly 穿透读（`getCookie(..., includeHttpOnly=true, ...)`）拿 CAS 后 `JSESSIONID`；
- ② `navigationAllow` 白名单闭锁（`ids`+`ehall`）+ `success.whenUrlMatches` 命中触发收割（ADR-015）；
- ③ **真机重点**：incognito 双实例隔离（A 登录、B 应未登录）+ 销毁后残留窗口压测（`clearSessionCookieSync` + `clearCache` 兜底时序）。

→ 标的 = XIDIAN IDS CAS（滑块用户手解），结论回写 **ADR-016 §2.4** 定最终 go/no-go。
**🔒 该阶段触红线 #1**：登录收割代码 + 测试须人工主导 + 安全清单 + ≥1 人工审，AI 不独自闭环。
