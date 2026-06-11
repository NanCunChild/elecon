// 引擎地板 canary —— 双跑漂移哨兵。详见 docs/adr/adr_006_client_runtime.md §3。
//
// 客户端 QuickJS（flutter_qjs vendored，Bellard 2021-03-27）与服务端 QuickJS-wasm
// （quickjs-emscripten RELEASE_SYNC，Bellard 2024-02-14）是**同一谱系的两个版本**。
// "同一引擎、零漂移"在引擎家族层面成立，但隔着 ES2022/2023/2024 的内建差异。
//
// 本 canary 只调用两端**共有的"地板"内建**，断言其行为逐字段一致；它挂在双跑
// 闸门上当**回归哨兵**：任一侧引擎在地板特性上行为漂移（或版本回退使地板特性消失）
// 即变红。它不试图"修复"版本差——那是迁移决策（把客户端对齐到 2024），见 ADR §3。
//
// 红线：**严禁在此调用 2022+ 内建**（.at / findLast / toSorted / toReversed /
// toSpliced / with / Object.groupBy / Map.groupBy 等）——它们在客户端 2021 缺失，
// 会抛 TypeError，使客户端半边变红。下方 `avoided` 列表把这条作者约束钉进 golden。
export const capabilities = {
  "__canary.engine_floor": (ctx, params, responses) => {
    return {
      // 共同地板：两端 QuickJS 都支持、且行为版本稳定的内建/语法。
      floor: {
        flatMap: [1, 2].flatMap((x) => [x, x * 10]), // [1,10,2,20]
        matchAll: [...'a1b2c3'.matchAll(/[a-z](\d)/g)].map((m) => m[1]), // ["1","2","3"]
        padStart: '5'.padStart(3, '0'), // "005"
        replaceAll: 'a.b.c'.replaceAll('.', '-'), // "a-b-c"
        hasOwn: Object.hasOwn({ x: 1 }, 'x'), // true（2021 已有，非分歧项）
        optionalChain: { a: { b: 2 } }.a?.b ?? -1, // 2
        nullish: {}.a?.b ?? -1, // -1
        // 注意：BigInt 不在地板内——客户端 fork 未开 CONFIG_BIGNUM，`2n` 字面量直接
        // 解析报错（canary 首跑即抓到）。它是**编译配置分歧**，见 avoided 与 ADR §3。
        toFixed: (0.1 + 0.2).toFixed(2), // "0.30"
        // 非整数键：插入序两端都保留（整数键会被规范重排，故刻意不用）。
        jsonKeyOrder: JSON.stringify({ b: 1, a: 2 }), // '{"b":1,"a":2}'
        // 稳定排序（ES2019 起规范保证；两端均为稳定实现）：相等 key 保持原相对序。
        sortStable: [
          { k: 1, i: 0 },
          { k: 1, i: 1 },
          { k: 0, i: 2 },
        ]
          .sort((p, q) => p.k - q.k)
          .map((o) => o.i), // [2,0,1]
      },
      // 客户端缺失、adapter **不得依赖**的能力（静态数据，两端等值——把作者约束钉进
      // golden）。两类成因：①编译配置（BigInt：fork 未开 CONFIG_BIGNUM）；
      // ②版本差（2021 vs 2024：以下 ES2022+ 内建）。见 ADR-006 §3。
      avoided: [
        'BigInt (2n literal / BigInt())',
        'Array.prototype.at',
        'String.prototype.at',
        'Array.prototype.findLast',
        'Array.prototype.findLastIndex',
        'Array.prototype.toSorted',
        'Array.prototype.toReversed',
        'Array.prototype.toSpliced',
        'Array.prototype.with',
        'Object.groupBy',
        'Map.groupBy',
      ],
    };
  },
};
