// fetch-response-shim.js —— adapter 所见的 ctx.fetch Response 接口 shim。
//
// 本文件内容被 sandbox.ts 以 readFileSync 读入，直接作为 QuickJS `evalCode` 的源码，
// 因此**整个文件必须是一个可求值的 JS 表达式**（下方括号包裹的箭头函数），
// 注释可保留（合法 JS），但不得有多余的顶层语句。
//
// 作用：把 Broker 的 raw fetch（返回 {status, headers, body}）封装为类 DOM Response
// 的接口：status / ok / headers / text() / json()。adapter 依赖这个 shape——
// 改动时必须保持向后兼容（契约面）。
//
// 原本内联于 sandbox.ts 的 ctx.evalCode 字符串参数，独立化便于审阅与将来加 golden。
(raw) => (url, init) =>
  raw(url, init).then((r) => ({
    status: r.status,
    ok: r.status >= 200 && r.status < 300,
    headers: r.headers,
    text: () => Promise.resolve(r.body === undefined ? "" : r.body),
    json: () => Promise.resolve(JSON.parse(r.body === undefined ? "null" : r.body)),
  }));
