# Adapter 发布 runbook：打包 · 签名 · 端点 D

> 状态：执行笔记（非 ADR）。  
> 历史关联：[V1 ADR-002](../adr/archived/v1/adr_002_trust_model.md) §2.3/§4、[V1 ADR-018](../adr/archived/v1/adr_018_adapter_distribution.md)、[`signing_ceremony.md`](./signing_ceremony.md)（密钥 ceremony）、[`tools/README.md`](../../tools/README.md)、[`deploy/public-endpoint/README.md`](../../deploy/public-endpoint/README.md)。
> **签名须持 YubiKey 的 release owner 在本地执行**（红线 #4；AI / CI 不得出签）。

---

## 0. 信任域与产物

| 域 | 谁做 | 产物 | 可否自动化 |
|---|---|---|---|
| **A** 社区/源码仓 | 贡献者 + CI | 源码、`npm run bundle` 的 **unsigned** envelope + digest | 是（预检） |
| **B** 审查（可选） | 维护者 | 二次校验；仍无签名 | 是 |
| **C** 签名 | **持 token 的人** | 签过的 bundle + catalog + revocation | **否**（PIN + 触碰） |
| **D** 公网分发 | CDN / 静态站 | 客户端拉取；**零凭证** | 上传可脚本化 |

客户端 fail-closed 顺序（不可改）：catalog 验签 + sequence → 下 bundle → 重算 digest → Ed25519 → revocation → `stdlibMin` → 加载。

**线上端点 D（当前）**：`https://elecon.xidian.one/adapters/`  
（客户端常量 `kDistributionBaseUrl`，见 `client/lib/core/adapter_service.dart`。）

```text
https://elecon.xidian.one/adapters/
├── catalog.json.gz
├── revocation.json
└── bundles/<digest>.json.gz
```

---

## 1. 源码与路径约定

| 角色 | 路径 |
|---|---|
| 社区 adapter 源（A，可领先核心） | `elecon-adapters/adapters/school-<id>/` |
| 核心仓 vendored 副本 | `elecon/adapters/school-<id>/`（可能滞后；**签哪份以 A 或你确认的源为准**） |
| 签名/打包工具 | `elecon/tools/` |
| 未签吊销输入 | `elecon/release/revocation.json` |
| 出签后 dist（不入仓，上传用） | 例如 `elecon/dist-xidian/` |
| App 内 bootstrap 基线 | `elecon/client/assets/bootstrap/`（从 dist **派生**，`npm run bootstrap:sync`） |

发布前确认：

- `manifest.trustTier === "official"`（否则 `release:package` fail-closed）
- capability ⊆ `contract/capability/registry.json`
- 夹具已脱敏；`npm run check`（adapters 仓）通过

---

## 2. A 域：unsigned bundle + digest

在 **adapters 源仓**（例：西电）：

```bash
cd ~/projects/elecon-adapters
npm run check
npm run bundle -- --adapter=school-xidian
npm run catalog   # 本地 unsigned 索引；不是线上 signed catalog

cat dist/bundles/school-xidian-<version>.sha256
```

产物（**不要**直接当端点 D 内容上传）：

```text
dist/bundles/school-xidian-<version>.json
dist/bundles/school-xidian-<version>.json.gz
dist/bundles/school-xidian-<version>.sha256
dist/catalog.json
```

---

## 3. 签前本地重算 digest（必做）

对「所见非所签」的唯一防线：在**即将触碰 YubiKey 的同一台机器**上重算，与 A 域 sha256 **逐字一致**。

```bash
cd ~/projects/elecon/tools
npx tsx src/signer/index.ts digest \
  --adapter=../../elecon-adapters/adapters/school-xidian
```

可选硬件自检（需 PIN + 触碰）：

```bash
npx tsx src/signer/pkcs11.ts list \
  --serial=<序列号> --module=/usr/lib/libykcs11.so
npx tsx src/signer/pkcs11.ts selftest \
  --serial=<序列号> --module=/usr/lib/libykcs11.so \
  --key-id=elecon-official-ncc-1
```

`pkcs11js` 仅签名机需要原生构建，见 `tools/README.md` Hardware Signing Setup。

---

## 4. C 域：一键签 dist（推荐）

`npm run release:package` 一次完成：

1. 校验 adapter 目录  
2. 建确定性 envelope、签 **bundle**  
3. 建并签 **catalog**（byte-exact `catalogJson`）  
4. 签 **revocation**  
5. 写出端点 D 树  

每次签名都会要 PIN；bundle / catalog / revocation 各至少一次触碰。

```bash
cd ~/projects/elecon/tools

npm run release:package -- \
  --adapters=../../elecon-adapters/adapters/school-xidian \
  --out=../dist-xidian \
  --base-url=https://elecon.xidian.one/adapters \
  --revocation=../release/revocation.json \
  --sequence=<线上 sequence + 1> \
  --ttl-seconds=86400 \
  --key-id=elecon-official-ncc-1 \
  --pkcs11-module=/usr/lib/libykcs11.so \
  --serial=<你的序列号> \
  --pinentry-command=/usr/bin/pinentry-qt
```

| 参数 | 说明 |
|---|---|
| `--adapters=` | 含 `manifest.json` 的目录**或**其父目录（会递归发现 official adapter） |
| `--out=` | dist 输出目录；上传此树到端点 D |
| `--base-url=` | **必须 https、无 userinfo**；写入 catalog 条目 `url`，须与客户端 base 一致 |
| `--revocation=` | **未签名**输入 JSON（`release/revocation.json`）；输出为已签 `revocation.json` |
| `--sequence=` | catalog **单调递增**（防回滚）；同端点更新必须 `> last published` |
| `--key-id=` / `--serial=` / `--pkcs11-module=` | 硬件签身份；默认 keyId `elecon-official-ncc-1` |
| `--pin-provider=tty` | 无 GUI pinentry 时改用终端 PIN |

成功输出示例：

```text
dist-xidian/
  catalog.json.gz
  revocation.json
  bundles/
    <digest>.json.gz
```

核对：

```bash
python3 - <<'PY'
import gzip, json
sc = json.load(gzip.open("../dist-xidian/catalog.json.gz"))
cat = json.loads(sc["catalogJson"])
print("sequence", cat["sequence"], "keyId", sc["keyId"])
for e in cat["entries"]:
    print(e["adapterId"], e["adapterVersion"], e["digest"])
    print(" ", e["url"])
    print(" ", e["capabilities"])
PY
```

### 注意

- **只传一个 adapter 目录时，catalog 仅含该条目**。同端点若需同时提供 helloworld 等多包，应把多个 official 目录放在同一根下再 `--adapters=` 一次出全量 catalog，或维护「全集」release 根，避免线上 catalog 被缩成单条。  
- `catalog.json.gz` 的 gzip **仅传输层**；CDN 用 `Content-Type: application/gzip`，**不要**再设 `Content-Encoding: gzip`。  
- **不要**上传 adapter 源码、未签 `release/revocation.json`、私钥或 ceremony 材料。

---

## 5. 上传到端点 D

把 **`dist-*/` 内全部文件**放到 base URL 对应静态根（路径与 catalog 内 `url` 一致）。

缓存建议（见 `deploy/public-endpoint`）：

| 路径 | Cache-Control |
|---|---|
| `bundles/*` | `public, max-age=31536000, immutable`（内容寻址） |
| `catalog.json.gz` / `revocation.json` | 短缓存（如 `max-age=60`） |

示例：

```bash
# rsync（路径按运维实际改）
rsync -av --delete \
  ~/projects/elecon/dist-xidian/ \
  user@host:/var/www/elecon/adapters/

# 本地 Docker 冒烟
docker build -t elecon-endpoint ~/projects/elecon/deploy/public-endpoint
docker run --rm -p 8080:80 \
  -v ~/projects/elecon/dist-xidian:/srv/dist:ro elecon-endpoint
curl -sI http://localhost:8080/catalog.json.gz

# 生产
curl -sI https://elecon.xidian.one/adapters/catalog.json.gz
curl -sI "https://elecon.xidian.one/adapters/bundles/<digest>.json.gz"
```

Node 自测：`PUBLIC_DIST_DIR=/abs/path/to/dist npm run start:public`（`server/`）。

---

## 6. （可选）同步 App bootstrap

bootstrap 是 dist 的**纯字节派生**，不是第二份手工副本。出签新 dist 后：

```bash
cd ~/projects/elecon/tools
npm run bootstrap:sync -- \
  --dist=../dist-xidian \
  --assets=../client/assets/bootstrap

# CI / 提交前只校验不写盘
npm run bootstrap:check -- --dist=../dist-xidian --assets=../client/assets/bootstrap
```

客户端对 bootstrap 仍走完整验签门。派生后的 `client/assets/bootstrap/**` 可随 app 提交；**`dist-*/` 本身通常不入核心仓**（只作上传工件）。

---

## 7. 发布台账

无云端逐次审计。每次 official 签名后向
[`release/adapter-release-ledger.json`](../../release/adapter-release-ledger.json) 追加记录并提交
（ADR-002 / ceremony §7）。该文件不属于 `contract/`，格式版本为
`elecon-adapter-release-ledger/v1`。

| 字段 | 说明 |
|---|---|
| `adapterId` / `adapterVersion` | 取自 bundle 内 manifest |
| `sourceCommit` | 已审 adapter 源的完整 40 位 commit SHA |
| `bundleDigest` | 规范化 envelope digest（64 位小写 hex） |
| `policy` | bundle 是否含 `masker.json`；若含，记录签名 envelope 内该文件字节的 SHA-256 |
| `catalogSequence` / `revocationSequence` | signed catalog / revocation 内的 sequence |
| `keyId` / `signedAt` | 出签 token 与实际签署时间 |
| `signer` / `reviewReference` | 实际触碰人和独立复核记录引用 |

工具只用 Node 内建验签能力，不出签、不加载 PKCS#11，也不把 artifact `issuedAt` 猜作实际签署时间。
extract 必须由 operator 显式提供受信 `keyId` 和对应的 32-byte Ed25519 裸公钥；工具先把 signed dist 中
catalog、revocation 和每个 bundle 的 `keyId` 与 operator 提供值比较，再逐一真实验签。不得省略参数或
静默读取仓内测试公钥。未知事实输出为显式 incomplete：

```bash
cd ~/projects/elecon
npm run ledger:extract -w tools -- \
  --dist=dist-xidian \
  --key-id=<operator-selected-trusted-key-id> \
  --public-key-hex=<matching-32-byte-ed25519-public-key-hex> \
  > /tmp/ledger-draft.json
```

release owner 从已审源码仓取得 commit，并提供实际 ceremony / 复核事实后，可一次生成完整草稿：

```bash
npm run ledger:extract -w tools -- \
  --dist=dist-xidian \
  --key-id=<operator-selected-trusted-key-id> \
  --public-key-hex=<matching-32-byte-ed25519-public-key-hex> \
  --source-commit=<40-hex-source-commit> \
  --signed-at=<RFC3339-time> \
  --signer=<actual-token-operator> \
  --review-reference=<PR-or-audit-reference>
```

把新记录按发布顺序追加后运行：

```bash
npm run ledger:validate
```

validator 拒绝未知字段、缺失却未声明的事实、重复记录、错误摘要，以及 catalog/revocation sequence
倒退。同一 `adapterId+adapterVersion` 即为同一身份，即使 digest 不同也会作为 equivocation 拒绝。
`status: "complete"` 不允许任何 `missingFacts`；历史资料尚缺时只能诚实保留 incomplete，不能据 git
author、文档作者或 `issuedAt` 补猜。普通 `ledger:validate` 分别报告结构有效性与历史完整性，空台账不会
被称为完整；需要执行严格历史门禁时显式追加 `-- --require-complete`。当前 CI 只做结构门禁，以免诚实的
空白历史令普通 CI 不可运行。

---

## 8. 实例：school-xidian@0.3.0（2026-07-21）

| 项 | 值 |
|---|---|
| 源 | `elecon-adapters/adapters/school-xidian` @ **0.3.0** |
| capabilities | `notice.list`, `schedule.week`, `grades.list`, **`exam.list`** |
| digest | `4a1031df1dd87ec7afbc038c10f16ae8464e22754a773b32d6bfda0699cbe90a` |
| catalog sequence | **2**（相对 helloworld bootstrap sequence=1） |
| keyId | `elecon-official-ncc-1` |
| issuedAt | `2026-07-21T11:18:20.614Z` |
| 线上 bundle URL | `https://elecon.xidian.one/adapters/bundles/4a1031df1dd87ec7afbc038c10f16ae8464e22754a773b32d6bfda0699cbe90a.json.gz` |
| 本地 dist | `elecon/dist-xidian/`（上传工件） |

命令复盘：

```bash
# A
cd ~/projects/elecon-adapters && npm run bundle -- --adapter=school-xidian

# digest 比对
cd ~/projects/elecon/tools
npx tsx src/signer/index.ts digest \
  --adapter=../../elecon-adapters/adapters/school-xidian
# → 4a1031df1dd87ec7afbc038c10f16ae8464e22754a773b32d6bfda0699cbe90a

# C
npm run release:package -- \
  --adapters=../../elecon-adapters/adapters/school-xidian \
  --out=../dist-xidian \
  --base-url=https://elecon.xidian.one/adapters \
  --revocation=../release/revocation.json \
  --sequence=2 \
  --key-id=elecon-official-ncc-1 \
  --pkcs11-module=/usr/lib/libykcs11.so \
  --serial=<序列号> \
  --pinentry-command=/usr/bin/pinentry-qt

# D：上传 dist-xidian/ → https://elecon.xidian.one/adapters/
# 可选 bootstrap
npm run bootstrap:sync -- --dist=../dist-xidian --assets=../client/assets/bootstrap
```

---

## 9. 与 ceremony 文档的分工

| 文档 | 内容 |
|---|---|
| [`signing_ceremony.md`](./signing_ceremony.md) | **密钥生成/PIN/触碰策略/公钥导出**；一次性或换钥 |
| **本文** | **每次 adapter 发版**：unsigned → digest 比对 → `release:package` → 上传 D → bootstrap / 台账 |
| [`tools/README.md`](../../tools/README.md) | 工具入口、helloworld 试发布示例 |
