# tools/ — 开发工具链（Node/TS）

> 语言选型见 [`docs/adr/adr_005_runtime.md`](../docs/adr/adr_005_runtime.md)：全栈统一到 JS/TS，契约校验用 `ajv`，与服务端共用一套。

| 工具 | 目录 | 用途 |
|---|---|---|
| validator | `src/validator/` | manifest 合法性校验（ajv）、白名单越界检查、sideload 强制 parser、fixture golden 测试 |
| codegen | `src/codegen/` | JSON Schema → Dart / TS 类型生成 |
| signer | `src/signer/` | 官方 adapter 签名 / 吊销 |
| release | `src/release/` | 生成 endpoint D 的 signed catalog、revocation 和 bundle dist |
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

## Release Packaging

release 只接受 official adapter，输出静态端点 D 所需的：

```text
dist/catalog.json.gz
dist/revocation.json
dist/bundles/<digest>.json.gz
```

签名时必须使用离线 YubiKey；release 默认通过 Linux `pinentry` 图形界面取得 PIN，不从命令行或环境变量读取。
如桌面环境未被 wrapper 正确识别，可显式指定 `--pinentry-command=/usr/bin/pinentry-qt`：

```bash
npm run release:package -- \
  --adapters=../adapters/school-xidian \
  --out=../dist \
  --base-url=https://dist.example.edu/ \
  --revocation=../release/revocation.json \
  --sequence=1
```

`catalog.json.gz` 的 gzip 只用于传输，签名对象仍是内部 `catalogJson` 原始 JSON 字节；不要在 CDN
设置 `Content-Encoding: gzip`，仅保留 `application/gzip` 内容类型。
