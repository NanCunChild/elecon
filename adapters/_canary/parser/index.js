// 引擎地板 canary —— 双跑漂移哨兵。版本差异与 avoided 清单见 ADR-008 §3。
export const capabilities = {
  "__canary.engine_floor": (ctx, params, responses) => {
    return {
      floor: {
        flatMap: [1, 2].flatMap((x) => [x, x * 10]),
        matchAll: [..."a1b2c3".matchAll(/[a-z](\d)/g)].map((m) => m[1]),
        padStart: "5".padStart(3, "0"),
        replaceAll: "a.b.c".replaceAll(".", "-"),
        hasOwn: Object.hasOwn({ x: 1 }, "x"),
        optionalChain: { a: { b: 2 } }.a?.b ?? -1,
        nullish: {}.a?.b ?? -1,
        toFixed: (0.1 + 0.2).toFixed(2),
        jsonKeyOrder: JSON.stringify({ b: 1, a: 2 }),
        sortStable: [
          { k: 1, i: 0 },
          { k: 1, i: 1 },
          { k: 0, i: 2 },
        ]
          .sort((p, q) => p.k - q.k)
          .map((o) => o.i),
      },
      avoided: [
        "BigInt (2n literal / BigInt())",
        "Array.prototype.at",
        "String.prototype.at",
        "Array.prototype.findLast",
        "Array.prototype.findLastIndex",
        "Array.prototype.toSorted",
        "Array.prototype.toReversed",
        "Array.prototype.toSpliced",
        "Array.prototype.with",
        "Object.groupBy",
        "Map.groupBy",
      ],
    };
  },
};
