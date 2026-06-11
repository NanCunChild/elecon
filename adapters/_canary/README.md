# `_canary` —— 双跑漂移哨兵（非业务 adapter）

这里**不是**学校 adapter，而是挂在双跑闸门（ADR-001 §8）上的引擎一致性哨兵。

## 为什么存在

客户端与服务端虽都是 QuickJS，但是**同一 Bellard 谱系的两个版本 + 不同编译配置**：

| 端 | 引擎 | QuickJS 源版本 | BigInt |
|---|---|---|---|
| 服务端 | `quickjs-emscripten@0.31` `RELEASE_SYNC` | Bellard **2024-02-14**（commit `36911f0d`） | 有 |
| 客户端 | `flutter_qjs`（fork）vendored | Bellard **2021-03-27** | **无**（CMake 未开 `CONFIG_BIGNUM`） |

二者隔着两类差异：**版本差**（ES2022/2023/2024 内建）+ **编译配置差**（客户端无 BigInt，`2n` 直接解析报错）。详见 [`docs/adr/adr_006_client_runtime.md`](../../docs/adr/adr_006_client_runtime.md) §3。

## `parser/`：`__canary.engine_floor`

只调用**两端共有的"地板"内建**，断言行为逐字段等于 `fixtures/engine_floor.json` 的 `expected`。
两端都应为绿——它守的是**回归**：任一侧引擎在地板特性上行为漂移、或版本回退使地板特性消失，闸门即变红。

`index.js` 里的 `avoided` 列表是**仅 2024 端有、2021 客户端缺失**的内建（`.at` / `findLast` /
`toSorted` / `Object.groupBy` 等）。adapter 作者在客户端对齐到 2024 之前**不得依赖**它们——
否则服务端跑过、客户端抛 `TypeError`，而双跑只在恰好命中的 fixture 上才抓得到。

## 跑它

- 服务端半边：`cd server && npm run smoke:sandbox`
- 客户端半边：`cd client && tool/build_qjs_test_lib.sh && flutter test test/dual_run_test.dart`
