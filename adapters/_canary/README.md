# `_canary` —— 双跑漂移哨兵（非业务 adapter）

挂在双跑闸门（ADR-001 §8）上的引擎一致性回归哨兵。只调用两端共有的"地板"内建，断言产出逐字段等于 golden；任一侧漂移即变红。

版本差异、`avoided` 清单与迁移策略见 [`docs/adr/adr_008_client_runtime.md`](../../docs/adr/adr_008_client_runtime.md) §3。

## 运行

- 服务端半边：`cd server && npm run smoke:sandbox`
- 客户端半边：`cd client && tool/build_qjs_test_lib.sh && flutter test test/dual_run_test.dart`

## 为何无 `manifest.json`

`_canary` **不是可分发 adapter**，故意不带 manifest：它由双跑 smoke 直接加载 `parser/index.js`，
不走 `tools/` 校验器。校验器的 `discoverAdapters` 只收集**含 `manifest.json`** 的目录，因此
`_canary` 被自动跳过（既不校验也不报错），`__canary.engine_floor` 也不进 `capability/registry.json`。
这是有意的：哨兵的契约是「逐字段等于 golden」，由 smoke 断言，而非 manifest/schema 静态校验。
