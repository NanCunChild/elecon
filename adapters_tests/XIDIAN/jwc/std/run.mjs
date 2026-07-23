// spike 运行器：用夹具喂 declarative requestGraph adapter，做 schema 结构校验 + golden 比对。
// 真实运行时是 QuickJS；node 仅用于本地验证 API 形态与产出（代码本身引擎地板安全）。
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { capabilities } from './index.mjs';

const dir = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(dir, 'fixtures/notice.sample.html'), 'utf8');

const ctx = { log: (l, m) => console.log(`  [ctx.${l}] ${m}`), now: () => Date.now() };
const out = capabilities['notice.list'](ctx, {}, { home: { status: 200, headers: {}, body: html } });

console.log('--- 产出 ---');
console.log(JSON.stringify(out, null, 2));

// elecon.notice.list 必填字段 + 枚举 + date-time 形态的子集校验
const CATS = ['academic', 'admin', 'event', 'unknown'];
const errs = [];
if (!out || !Array.isArray(out.items)) {
  errs.push('items 非数组');
} else if (out.items.length === 0) {
  errs.push('items 为空（定位失败？）');
} else {
  out.items.forEach((it, idx) => {
    ['id', 'title', 'publishedAt', 'category', 'source'].forEach((f) => {
      if (typeof it[f] !== 'string' || !it[f]) errs.push(`item[${idx}].${f} 缺失`);
    });
    if (CATS.indexOf(it.category) < 0) errs.push(`item[${idx}].category 非法: ${it.category}`);
    if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/.test(it.publishedAt)) errs.push(`item[${idx}].publishedAt 非 date-time`);
    if (it.url && !/^https?:\/\//.test(it.url)) errs.push(`item[${idx}].url 非 uri`);
  });
}

const goldenPath = join(dir, 'fixtures/notice.golden.json');
let goldenResult = 'SKIP（无 golden）';
if (existsSync(goldenPath)) {
  const golden = JSON.parse(readFileSync(goldenPath, 'utf8'));
  goldenResult = JSON.stringify(out) === JSON.stringify(golden) ? 'PASS' : 'FAIL';
}

console.log('--- 结果 ---');
console.log('schema 结构校验:', errs.length ? 'FAIL — ' + errs.join('; ') : 'PASS');
console.log('golden 比对:', goldenResult);
process.exit(errs.length || goldenResult === 'FAIL' ? 1 : 0);
