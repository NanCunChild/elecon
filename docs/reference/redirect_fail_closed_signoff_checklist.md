# P0-05 Redirect Fail-Closed 人工复签清单

> 对应 ADR-009 §2.5 rev-5、红线 #1。2026-08-07 辅助核查发现旧实现会把 security-blocked 3xx 交给 adapter；现已修复并通过自动化测试，但自动测试不能替代 owner 对承重代码和测试的人工签收。

## 决策复核

- [x] 接受 `deliver / follow / blocked` 三态；`blocked` 不再表示“停止并交付当前响应”。
- [x] 接受 301/302/303/307/308 的 `Location=null` 或空字符串为正常 non-follow terminal response；300/304 等非自动跟随状态正常交付。
- [x] 接受 outside allow、max hops、非空不可解析 Location 为 `blocked`，抛稳定 `BrokerFetchRejected`。
- [x] 接受 transport 晚到后 cancellation-before-side-effects 的顺序。

## 代码复核

- [x] `server/src/runtime/broker/redirect.ts` 与 `client/lib/core/broker/redirect.dart`：blocked outcome 不携带 response status/body/header/Location。
- [x] `server/src/runtime/broker/fetch-proxy.ts` 与 `client/lib/core/broker/fetch_proxy.dart`：cancel/blocked 检查发生在 CookieJar、query harvest、raw callback、firewall/processResponse 之前。
- [x] blocked 不调用 `onRawResponse` / `onRedirectSettled`，不启动下一跳，不返回 adapter-visible Response。
- [x] follow/deliver 仍正常 capture Set-Cookie；只有确定 follow 后才 query harvest。

## 测试复核

- [x] `contract/golden/broker/redirect.json` 的 20 个双端向量覆盖 null/空 Location、300/304、outside allow、max hops、非法非空 Location。
- [x] TS `assemble.smoke.ts` 与 Dart `broker_fetch_proxy_test.dart` 使用 poison body、`ETag`、Set-Cookie、query token，证明 blocked 响应零交付、零副作用。
- [x] TS/Dart 晚到 302 取消用例证明不收割、不回调、不发下一跳。
- [x] 正常 terminal 302、正常重定向链及 401/403/5xx 行为未回归。

## 签收

- [x] owner 已逐行复核上述实现和测试，同意 ADR-009 rev-5。
- [x] owner 授权把 `docs/planning/2026_08_review_remediation.md` 的 P0-05 标记为 `[x]`。

签收记录：

- Reviewer： NanCunChild
- 日期： 2026-08-07
- 关联 PR / commit：
