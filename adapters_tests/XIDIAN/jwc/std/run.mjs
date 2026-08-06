// 标准 declarative fixture replay：执行 handler，逐字段比较 expected，再校验真实 contract schema。
import { strict as assert } from 'node:assert';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Ajv2020 } from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { capabilities } from './index.js';

const dir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(dir, '../../../..');
const fixture = JSON.parse(readFileSync(join(dir, 'fixtures/notice.list.json'), 'utf8'));
const responses = {};
for (const [key, response] of Object.entries(fixture.responses)) {
  responses[key] = {
    status: response.status,
    headers: response.headers || {},
    body: response.bodyFile ? readFileSync(join(dir, response.bodyFile), 'utf8') : response.body || '',
  };
}

const handler = capabilities[fixture.capability];
assert.equal(typeof handler, 'function', `缺 capability handler：${fixture.capability}`);
const ctx = { log: () => {}, now: () => 1_700_000_000_000 };
const actual = handler(ctx, fixture.params || {}, responses);
assert.deepStrictEqual(actual, fixture.expected, 'handler 产出与 fixture expected 不一致');

const schema = JSON.parse(
  readFileSync(join(repoRoot, 'contract/schema/notice.list.schema.json'), 'utf8'),
);
const ajv = new Ajv2020({ allErrors: true, strict: false });
addFormats(ajv);
const validate = ajv.compile(schema);
assert.ok(validate(actual), `产出未通过 elecon.notice.list：${JSON.stringify(validate.errors)}`);

console.log('XIDIAN jwc std：fixture replay + expected + contract schema 通过');
