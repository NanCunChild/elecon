# server/ — Node/TS 服务端

> 运行时选型见 [`docs/adr/adr_005_runtime.md`](../docs/adr/adr_005_runtime.md)：
> **TypeScript on Node**（不是裸 Node），adapter 用 **QuickJS-wasm** 执行（不用 Node 的 `vm`）。

## 结构

```
src/
  public/      公网哑服务（无状态、零凭证）
  campus/      校内授权中继（堡垒机后部署，承重路径）
  runtime/     adapter 执行沙箱（QuickJS-wasm / quickjs-emscripten）
    __testutils__/  共享冒烟测试工具（resolveRepoRoot / FakeResolver / FakeTransport / runMain）
    broker/         能力 broker（B1-B6，与 client 镜像）
    credential/     凭证存储
    transport/      传输层
```

## 运行

```bash
npm install
npm run dev:public     # 公网哑服务
npm run dev:campus     # 校内授权中继（需校内部署）
npm run typecheck      # 严格类型检查
```

## 原则

- `src/public` 零凭证、无状态——仅分发 adapter + 缓存公开数据（红线 #2）。
- `src/campus` 在校内堡垒机后代取私密数据，**经手凭证 = 承重路径**：锁 lockfile、最小依赖、定期 `npm audit`（ADR-005 §3.3）。
- adapter 用 **QuickJS-wasm** 执行，与客户端 QuickJS 是同一个引擎，零语义漂移；**绝不用** Node 的 `vm`（`vm` 不是安全边界）。
- 全程 TypeScript `strict`；契约校验用 `ajv`，与 `tools/` 共用一套。
