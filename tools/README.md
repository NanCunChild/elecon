# tools/ — 开发工具链（Node/TS）

> 语言选型见 [`docs/adr/adr_005_runtime.md`](../docs/adr/adr_005_runtime.md)：全栈统一到 JS/TS，契约校验用 `ajv`，与服务端共用一套。

| 工具 | 目录 | 用途 |
|---|---|---|
| validator | `src/validator/` | manifest 合法性校验（ajv）、白名单越界检查、sideload 强制 parser、fixture golden 测试 |
| codegen | `src/codegen/` | JSON Schema → Dart / TS 类型生成 |
| signer | `src/signer/` | 官方 adapter 签名 / 吊销 |
| scanner | `src/scanner/` | 夹具 PII 扫描（脱敏检查） |

## 运行

```bash
npm install
npm run validate     # 校验 adapter
npm run codegen      # 生成类型
npm run sign         # 签名
npm run scan         # 扫描夹具
npm run typecheck    # 严格类型检查
```
