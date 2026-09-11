# tools/ — 开发工具链（Node/TS）

> 语言选型见 [`docs/adr/adr_005_runtime.md`](../docs/adr/adr_005_runtime.md)：全栈统一到 JS/TS，契约校验用 `ajv`，与服务端共用一套。

| 工具 | 目录 | 用途 |
|---|---|---|
| validator | `src/validator/` | manifest 合法性校验（ajv）、白名单越界检查、sideload 强制 declarative requestGraph、fixture golden 测试 |
| codegen | `src/codegen/` | JSON Schema → Dart / TS 类型生成 |
| signer | `src/signer/` | 官方 adapter 签名 / 吊销 |
| release | `src/release/` | 生成 endpoint D 的 signed catalog、revocation 和 bundle dist；从 dist 派生客户端 bootstrap 基线资产 |
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

## Bootstrap 基线派生

客户端随 app 打包的 bootstrap 基线（`client/assets/bootstrap/`）是 dist 树的**纯字节派生**，不是
另一份手工维护的副本（catalog = gunzip、revocation/bundle = 复制）。**dist 是单一真值源**；出签
新 dist 后运行下面命令重新派生，避免两处漂移：

```bash
npm run bootstrap:sync                 # 默认 dist-full → client/assets/bootstrap
npm run bootstrap:sync -- --dist=../dist --assets=../client/assets/bootstrap
```

CI/提交前用 `--check` 只校验不写盘，任一派生文件与 dist 不一致即非零退出：

```bash
npm run bootstrap:check
```

该命令不签名、不改动 dist；bootstrap 与线上产物同格式，客户端 loader 仍对其重跑验签 + 各门后才采用。

## Hardware Signing Setup

`pkcs11js` 是可选的原生依赖：普通开发、校验、扫描、smoke 和验签不需要它；只有实际使用
YubiKey 出签的离线签名机需要构建 `pkcs11.node`。仓库的 npm 安装策略默认阻止依赖安装脚本，
因此 `npm rebuild pkcs11js` 可能显示成功但仍不会生成原生模块。推荐显式构建该模块：

```bash
cd tools
PKCS11_DIR="$(npm root)/pkcs11js"
cd "$PKCS11_DIR"
npx node-gyp rebuild
node -e "require('pkcs11js'); console.log('pkcs11js native module loaded')"
cd -
```

签名机需要预先安装 C/C++ 构建工具、Python、Node.js headers，以及 YubiKey 的 PKCS#11 模块
（通常为 `libykcs11.so`）。`pkcs11js` 是 Node 到 PKCS#11 的桥接模块，`--pkcs11-module`
则是 YubiKey 厂商库路径，两者都必须存在；不能用 `--pkcs11-module=/path/to/...` 这样的占位路径。

先确认令牌和签名槽位，再执行真实签名：

```bash
cd tools
npx tsx src/signer/pkcs11.ts list \
  --serial=36415367 \
  --module=/usr/lib/libykcs11.so

npx tsx src/signer/pkcs11.ts selftest \
  --serial=36415367 \
  --module=/usr/lib/libykcs11.so
```

`selftest` 会执行真实签名，需要 PIN 和物理触碰。签名前必须人工确认待签 adapter、digest、
`keyId` 和输出目录；密钥 ceremony 不由脚本自动执行。

## HelloWorld Test Release

仓库包含一个不访问网络、不使用凭证的 `adapters/school-helloworld`，用于验证端点 D → 客户端
接收 → 验签 → 加载 → QuickJS 执行 → 日志/产出链路：

```bash
cd tools
npm run release:package -- \
  --adapters=../adapters/school-helloworld \
  --out=../dist-full \
  --base-url=https://elecon.xidian.one/adapters \
  --revocation=../release/revocation.json \
  --sequence=1 \
  --key-id=elecon-official-ncc-1 \
  --pkcs11-module=/usr/lib/libykcs11.so \
  --serial=36415367 \
  --pinentry-command=/usr/bin/pinentry-qt
```

命令会生成 `catalog.json.gz`、签名 `revocation.json` 和 `bundles/<digest>.json.gz`。上传时将
`dist-full/` 内的内容直接放到远端 `/adapters/` 目录，不要上传原始 adapter 源码、私钥或
输入用的未签名 `release/revocation.json`。
