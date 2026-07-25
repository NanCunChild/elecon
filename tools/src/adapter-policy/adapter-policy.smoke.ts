/** 🔒 红线 #5 对抗回归；安全闸门仍须人工实质审阅（ADR-018 §2.10）。 */

import { strict as assert } from "node:assert";
import { AdapterPolicyError, checkAdapterSourcePolicy } from "./index.js";

const manifest = {
  capabilities: [
    { id: "notice.list", requestGraph: "declarative" },
    { id: "grades.list", requestGraph: "imperative" },
  ],
};

function accept(source: string): void {
  assert.doesNotThrow(() => checkAdapterSourcePolicy("school-test", source, manifest));
}

function reject(source: string, message: string): void {
  assert.throws(() => checkAdapterSourcePolicy("school-test", source, manifest), AdapterPolicyError, message);
}

accept(`
  import { parseDocument } from "elecon:html";
  export const capabilities = {
    "notice.list": (_ctx, _params, responses) => parseNotice(responses.page.body),
    "grades.list": async (ctx) => (await ctx.fetch("https://example.test")).json(),
  };
  function parseNotice(html) { return { items: parseDocument(html) ? [] : [] }; }
`);

reject(
  `export const capabilities = { "notice.list": (ctx) => ctx.fetch("https://evil.test") };`,
  "直接 ctx.fetch 必须拒绝",
);

reject(
  `
    export const capabilities = { "notice.list": (_ctx) => helper() };
    function helper() { return fetch("https://evil.test"); }
  `,
  "可达 helper 必须拒绝",
);

reject(
  `
    export const capabilities = { "notice.list": (_ctx) => new Escape().run() };
    class Escape { run() { return fetch("https://evil.test"); } }
  `,
  "可达 class 必须拒绝",
);

reject(
  `export const capabilities = { "notice.list": (ctx) => ctx["fe" + "tch"]("https://evil.test") };`,
  "计算属性绕过必须因读取 ctx 被拒绝",
);

reject(
  `
    const fakecapabilities = { "notice.list": () => ({ items: [] }) };
    export const capabilities = { "notice.list": (ctx) => ctx.fetch("https://evil.test") };
  `,
  "伪 capabilities 锚点不得遮蔽真实导出",
);

reject(
  `export { helper } from "./evil.js"; export const capabilities = { "notice.list": () => ({ items: [] }) };`,
  "re-export 必须受 import 白名单约束",
);

reject(
  `export const capabilities = { "notice.list": async () => import("elecon:html") };`,
  "动态 import 一律拒绝",
);

reject(
  `export const capabilities = { "notice.list": ({ fetch }) => fetch("https://evil.test") };`,
  "ctx 解构必须拒绝",
);

reject(
  `
    let helper;
    helper = () => fetch("https://evil.test");
    export const capabilities = { "notice.list": () => helper() };
  `,
  "顶层可变绑定和赋值不得绕过可达性分析",
);

reject(
  `
    const eager = (() => fetch("https://evil.test"))();
    export const capabilities = { "notice.list": () => ({ items: [eager] }) };
  `,
  "模块加载时 IIFE 必须拒绝",
);

console.log("adapter-policy smoke: all assertions passed");
