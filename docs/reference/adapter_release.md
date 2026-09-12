# Adapter 发布 runbook：打包 · 签名 · 端点 D

> 状态：执行笔记（非 ADR）。  
> 关联：[`adr_002`](../adr/adr_002_trust_model.md) §2.3/§4、[`adr_018`](../adr/adr_018_adapter_distribution.md)、[`signing_ceremony.md`](./signing_ceremony.md)（密钥 ceremony）、[`tools/README.md`](../../tools/README.md)、[`deploy/public-endpoint/README.md`](../../deploy/public-endpoint/README.md)。  
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

**dist 树端点无关**（ADR-018 §2.5.1）：catalog 只列 digest、不含 URL；bundle 恒在 `bundles/<digest>.json.gz`，
客户端按**自持** base URL 拼路径。同一份签名产物可放官方端点、镜像或本地 nginx，**无需重签**。

**线上端点 D（当前）**：`https://elecon.xidian.one/adapters/`  
（客户端常量 `kDistributionBaseUrl`，见 `client/lib/core/adapter_service.dart`；DEV-Sideload 可
`--dart-define=ELECON_DISTRIBUTION_BASE_URL=http://127.0.0.1:8080/` 指向本地端点冒烟。）

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
| 出签后 dist（**不入仓**，`.gitignore` 已排除 `/dist-*/`） | 例如 `elecon/dist-full/`，仪式后立即 `bootstrap:sync` 进仓 |
| **唯一入库的签名产物** | `elecon/client/assets/bootstrap/`（dist 的纯字节派生；上传时 `npm run dist:export` 反向导出） |

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

产物（**不要**直接当端点 D 内容上传）——**2026-09-09 digest v2 后文件名已变**：

```text
dist/bundles/school-xidian-<version>.envelope.json      # 被签的那串字节本身
dist/bundles/school-xidian-<version>.unsigned.json.gz   # {envelopeB64, blobs}，缺 signature
dist/bundles/school-xidian-<version>.sha256             # = SHA-256(envelope.json)
dist/catalog.json
```

> **`.envelope.json` 是被签对象、不是可加载产物**：v2 的 digest 覆盖的就是这串字节，故 A 域**只写
> 这一份**，不再另出 pretty-print 版本——同时存在「好看的一份」和「被签的一份」正是 ADR-018 §3
> 风险 (e)「所见非所签」的温床。`.unsigned.json.gz` 是**未签名交接物**（传输封套缺 `signature`
> 一项），补上签名后才是可加载的封套。

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
  --adapters=../../elecon-adapters/adapters \
  --out=../dist-full \
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
| `--out=` | dist 输出目录（不入仓）；随后 `bootstrap:sync` 进仓 |
| ~~`--base-url=`~~ | **已移除**（2026-09-11，ADR-018 §2.5.1）：catalog 不再描述端点，传了会报错 |
| `--revocation=` | **未签名**输入 JSON（`release/revocation.json`）；输出为已签 `revocation.json` |
| `--sequence=` | catalog **单调递增**（防回滚）；打包器以入库 bootstrap 为基线强制 `> 已签发`，revocation 同序号改内容也拒（P3-08） |
| `--baseline=` / `--no-baseline` | 基线目录缺省 `client/assets/bootstrap`；**仅首次发布**可 `--no-baseline` |
| `--key-id=` / `--serial=` / `--pkcs11-module=` | 硬件签身份；默认 keyId `elecon-official-ncc-1` |
| `--pin-provider=tty` | 无 GUI pinentry 时改用终端 PIN |

成功输出示例：

```text
dist-full/
  catalog.json.gz
  revocation.json
  bundles/
    <digest>.json.gz
```

核对：

```bash
python3 - <<'PY'
import gzip, json
sc = json.load(gzip.open("../dist-full/catalog.json.gz"))
cat = json.loads(sc["catalogJson"])
print("sequence", cat["sequence"], "keyId", sc["keyId"])
for e in cat["entries"]:
    print(e["adapterId"], e["adapterVersion"], e["digest"])
    print(" ", e["capabilities"])
    assert "url" not in e, "catalog 不应再含 url（ADR-018 §2.5.1）"
PY
```

### 注意

- **只传一个 adapter 目录时，catalog 仅含该条目**。同端点若需同时提供 helloworld 等多包，应把多个 official 目录放在同一根下再 `--adapters=` 一次出全量 catalog，或维护「全集」release 根，避免线上 catalog 被缩成单条。  
- `catalog.json.gz` 的 gzip **仅传输层**；CDN 用 `Content-Type: application/gzip`，**不要**再设 `Content-Encoding: gzip`。  
- **不要**上传 adapter 源码、未签 `release/revocation.json`、私钥或 ceremony 材料。

---

## 5. 上传到端点 D

上传物**从入库的 bootstrap 导出**（不要上传仪式当天那棵未入库的 dist——两者签名范围内逐字节相同，但入库的才是经 CI `bootstrap:verify` 过门的）：

```bash
cd ~/projects/elecon/tools
npm run dist:export            # → ../dist-export/{catalog.json.gz, revocation.json, bundles/}
```

把导出树内全部文件放到 base URL 对应静态根（`<base>/catalog.json.gz`、`<base>/bundles/<digest>.json.gz`）。

缓存建议（见 `deploy/public-endpoint`）：

| 路径 | Cache-Control |
|---|---|
| `bundles/*` | `public, max-age=31536000, immutable`（内容寻址） |
| `catalog.json.gz` / `revocation.json` | 短缓存（如 `max-age=60`） |

示例：

```bash
# rsync（路径按运维实际改）
rsync -av --delete \
  ~/projects/elecon/dist-full/ \
  user@host:/var/www/elecon/adapters/

# 本地 Docker 冒烟
docker build -t elecon-endpoint ~/projects/elecon/deploy/public-endpoint
docker run --rm -p 8080:80 \
  -v ~/projects/elecon/dist-full:/srv/dist:ro elecon-endpoint
curl -sI http://localhost:8080/catalog.json.gz

# 生产
curl -sI https://elecon.xidian.one/adapters/catalog.json.gz
curl -sI "https://elecon.xidian.one/adapters/bundles/<digest>.json.gz"
```

Node 自测：`PUBLIC_DIST_DIR=/abs/path/to/dist npm run start:public`（`server/`）。

---

## 6. 同步 App bootstrap（**必做**——这是唯一入库的签名产物）

bootstrap 是 dist 的**纯字节派生**。出签新 dist 后**立即**派生并提交；dist 本身不入仓：

```bash
cd ~/projects/elecon/tools
npm run bootstrap:sync -- --dist=../dist-full        # dist → client/assets/bootstrap
npm run bootstrap:verify                             # 自洽门（CI 同款）：catalog ↔ bundles ↔ envelope digest
git add ../client/assets/bootstrap && git commit …   # 连同 §7 台账一起提交
```

`bootstrap:verify` 不验签（那是客户端 loader 的事），只证入库树内部一致：每个 entry.digest 都有 bundle、
无游离 bundle 随 app 发布、每个 bundle 文件名就是其 envelope 的真实 digest。客户端对 bootstrap 仍走完整验签门。

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
  --dist=dist-full \                 # 仪式当天的 dist；事后可用 dist:export 的导出树
  --key-id=<operator-selected-trusted-key-id> \
  --public-key-hex=<matching-32-byte-ed25519-public-key-hex> \
  > /tmp/ledger-draft.json
```

release owner 从已审源码仓取得 commit，并提供实际 ceremony / 复核事实后，可一次生成完整草稿：

```bash
npm run ledger:extract -w tools -- \
  --dist=dist-full \
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

> ⚠ **这是 `elecon-bundle/1` 时代的记录，留作流程范例**。其中的 digest（`4a1031df…`）是 v1 算法产物，
> **在 v2 下不可复现**；A 域产物文件名已变（§2）；`--base-url` 参数已于 2026-09-11 移除（§4）、「线上 bundle URL」
> 一行现在由客户端 base + digest 拼出而非写在 catalog 里。

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
| **本文** | **每次 adapter 发版**：unsigned → digest 比对 → `release:package` → `bootstrap:sync` 入仓 + 台账 → `release:gate` → `dist:export` 上传 D；§10 发版门与吊销演练 |
| [`tools/README.md`](../../tools/README.md) | 工具入口、helloworld 试发布示例 |

---

## 10. 发版门与急性吊销演练（P3-08）

### 10.1 发版门

`npm run release:gate -w tools` 只读检查**入库的** `client/assets/bootstrap/`（随 app 打包、也是上传源）：

| 项 | 判据 | 结果 |
|---|---|---|
| G1 | catalog / revocation 的 keyId ∈ 客户端 `trust_anchors.dart` 的 active 锚，且以该公钥真实验签 | error |
| G2 | revocation 在 TTL 内、issuedAt 不超前 >5 分钟 | error（PR CI 降为 warn）；catalog 过 TTL 只 warn |
| G3 | revocation.killSwitch 为 false | error，`--allow-kill-switch` 放行 |
| G4 | 每个 catalog entry 在台账有**同 digest** 的首签记录（身份只记一次，字节没变就沿用），记录序号 ≤ bootstrap；台账最大序号 ≤ bootstrap | error |
| G5 | `release/revocation.json` sequence ≥ 已签；相等时内容逐字段相同 | error |
| G6 | `--online-base=` 给出时，bootstrap sequence ≥ 线上 | error；拉不到也 error |

接线：PR CI 每次跑（G2 过期只告警）；`release.yml` 经 `release_gate: true` 让 G2 硬失败。
打包器 `release:package` 另在**签名前**按基线拒绝 catalog 序号不严格递增、revocation 倒退或同序号改内容（§4）。

> **TTL 的语义**（ADR-002 §2.4，2026-09-12 明确）：TTL 只是陈旧度信号，**客户端从不因过期拒载**；急性吊销靠在线拉取
> + sequence + kill-switch，与 TTL 无关。它唯一硬性约束的是本门 G2：不把一份已过期的基线打进新装包。
> 当前线上 revocation seq 2 为 7 天 TTL（2026-09-18T06:31Z 到期）；`release/revocation.json` 已预备 **seq 3 / 180 天**，
> 随下次仪式签发（仪式当天刷新 `issuedAt`）。

### 10.2 急性吊销演练（无需真事故，建议每次换钥或季度做一次）

目标：从「决定吊销」到「线上 + 仓内都生效」走完整条链，并让发版门证明中间没有一步被跳过。

1. 改 `release/revocation.json`：`sequence` +1，`issuedAt` 改为现在，按需加 `entries[]`（按 digest 或版本区间）、
   `minVersions`，或在密钥泄露事件下置 `killSwitch: true`。
2. **先跑门看它拒什么**：`npm run release:gate -w tools` 此时应报 G5「内容已改但 sequence 未 bump」——
   若你漏了第 1 步的 bump；bump 后应通过（输入领先已签是合法的「已准备」状态）。
3. `release:package`（§4，需 YubiKey；catalog `--sequence` 亦 +1）→ `bootstrap:sync` → `bootstrap:verify`。
4. `release:gate`：若本次有新 adapter 字节，G4 会报「未入台账」——补台账（§7 `ledger:extract`，只追加新身份）后再跑，应通过；
   仅重签 catalog/revocation、adapter 字节未变时不需要新记录；
   若置了 killSwitch，门会 G3 拒，须 `--allow-kill-switch` 明确放行。
5. `dist:export` → 上传 → `release:gate --online-base=<base>`：线上与 bootstrap 一致即通过。
6. 演练结束若是假吊销，再走一遍 1–5 把它撤回（sequence 继续递增，**不回滚**）。
