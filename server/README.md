# server/ — Node/TS 公网服务与审核工具

V2 服务端不是 adapter 的产品运行目标。项目不提供校内授权中继；公网服务不执行任何
adapter，不接触凭证、用户会话或私密校园响应。决策见
[`ADR-001`](../docs/adr/adr_001_project_shape.md)。

## 结构

```text
src/
  public/      公网静态分发服务：无状态、零凭证、不执行 adapter
  runtime/     V1 迁移期与审核辅助代码；不是 V2 产品 runtime
```

`src/runtime/` 中现有 QuickJS-wasm、Broker 和 smoke 在客户端 fixture gate 接管前作为
legacy baseline 保留。它们不得被描述为与客户端 runtime 等价，也不得承接 public 请求。

## 运行

```bash
npm install
npm run dev:public
npm run typecheck
npm run smoke:all
```

## 原则

- `src/public` 当前仍按原字节分发 V1 migration baseline 的 bundle、signed catalog 和 revocation。ADR-005 落地后改为分发自包含 `.eleb`、非权威 discovery index 和独立 revocation；public 始终不参与执行信任。
- public 不读取 Cookie/Authorization，不加载 adapter entry，不导入 `src/runtime`。
- server replay 只能辅助审核；official 发布必须包含客户端目标 runtime 的 fixture 证据。
- `src/campus` 已退役并删除，不得重新引入项目中继或私密代理入口。
- 全程 TypeScript `strict`；契约工具可以复用 `ajv`，但不建立客户端/服务端 runtime 一致性承诺。
