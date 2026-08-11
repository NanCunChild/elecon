# ADR-005：Manifest V2、adapter bundle 与开发模型

- **状态**：提议（Proposed）
- **日期**：2026-08-11
- **依赖**：[ADR-002](./adr_002_execution_trust.md)、[ADR-003](./adr_003_core_security_boundary.md)、[ADR-004](./adr_004_credential_store.md)

## 1. 单一 adapter 形态

V2 只保留普通异步 JavaScript capability handler。删除 declarative/imperative 双 requestGraph、`requests/bind/compute/inject`、opaque handle、dataflow crypto op 和 mandatory Response Masker。

adapter 作者使用熟悉的流程：

```js
export const capabilities = {
  async "grades.list"(ctx, params) {
    const credentials = await ctx.credentials.list({ school: params.school });
    const response = await ctx.fetch(buildUrl(params), buildRequest(credentials));
    return normalize(await response.json());
  },
};
```

## 2. Manifest V2

manifest 只声明静态、可审查和可由宿主强制的事实：

- adapter identity、version、entry；
- contract、SDK、host 和 QuickJS compatibility；
- capabilities、params 与 emits schema；
- network scheme/origin/path/method；
- 宿主 WebView 登录计划；
- 资源预算和必要静态元数据。

manifest 不自报 official、signed 或用户信任。网络声明是宿主强制上限，不是防止受信 adapter 外泄数据的证明。

## 3. SDK

V2 SDK 提供 `ctx.fetch`、Credential Store、受控日志、确定性时间/取消信号和宿主登录请求。adapter 不获得 UI、WebView 对象、transport 选择权或 native module。

bundle 必须确定性打包，审核、官方签名和 local trust 都指向相同 exact bytes/digest。源码、依赖锁、生成物、资源和实际执行入口必须闭合，禁止审核源码后执行未纳入 digest 的依赖。

## 4. 开发责任

- fixture 必须脱敏；认证测试使用合成值或测试账号。
- 作者准确声明网络并解释凭证、日志和持久化行为。
- source policy 可限制 dynamic import、`eval`、隐蔽资源和超大 bundle，以提高可审性，但不伪装成恶意代码证明。
- 统一 template、类型和 replay 工具，减少私有 API 学习成本。

## 5. 迁移

先实现 Manifest V2 与统一 runtime，再转换 pinned adapters。所有 adapter 和 fixture 转换完成且 V2 gates 阻塞通过后，才能删除 V1 contract/runtime；不长期维护双栈。
