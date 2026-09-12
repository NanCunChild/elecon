# Adapter 包与签名机制 · 快速入门

> 写给第一次给 elecon 写 adapter 的外部贡献者。它只讲**一件事**：你交出去的那个目录，
> 是怎么变成用户设备上运行的东西的——谁碰过它、谁给它背书、你在这条链上能做什么、不能做什么。
> 按当前形态（digest v2、catalog 只描述文件）维护；规格变了本文同批改。
>
> **它不替代任何 ADR、契约或规则文档**，也不是权威。真正说了算的是：
> [`adr_002`](../adr/adr_002_trust_model.md)（信任模型）、
> [`adr_018`](../adr/adr_018_adapter_distribution.md)（分发与包形态）、
> [`contract/manifest.schema.json`](../../contract/manifest.schema.json)（字段定义）、
> [`docs/rules/`](../rules/)（贡献规则）。本文与它们冲突时，**以它们为准**。
>
> **术语（ADR-000 §2.3.1）**：本文所称 **envelope / 信封**一律指 **bundle 信封**——你的包的
> 清单 + 被签的那个对象。它与运行期包裹成绩/课表数据的 **数据信封**（`elecon.envelope`）
> **是两样东西**，只是撞名；你写 adapter 时产出的是后者，签名签的是前者。

---

## 0. 五分钟版

1. 你写的是**一个目录**：`manifest.json` + `index.js`（+ 可选运行时资产 + `fixtures/`）。
2. `fixtures/`、`README.md` **不会**进交付包——它们是开发期产物。
3. 你**永远拿不到用户凭证的值**。你在 manifest 里写的是 `ref`（引用名），核心负责注入。
4. 你**不持任何私钥**，社区仓库的 CI **也没有签名能力**。签名是维护者在离线机上按硬件令牌完成的一步。
5. 你改任何一个进包的字节，包的 `digest` 就会变；`digest` 变了，就必须**重新签名**才能分发。
6. 签名保证的是「这些字节确实是官方审过并批准的」。它**不**保证你的代码没 bug，也**不**给你任何额外权限。

---

## 1. 你交出去的是什么形态

### 1.1 你的工作目录

```
adapters/school-yourschool/
├── manifest.json      ← 契约声明：身份、能力、出网白名单、凭证引用、登录配置
├── index.js           ← 入口代码（由 manifest.runtime.entry 指定）
├── masker.json        ← 响应策略（official 包必需；rules 可为空，但文件不能缺）
├── assets/…           ← 可选运行时资产
├── fixtures/…         ← 测试夹具（**不进交付包**）
└── README.md          ← 说明（**不进交付包**）
```

参考 `adapters/_template/declarative/` 与 `adapters/_template/imperative/` 两个模板，
以及最小可跑的 `adapters/school-helloworld/`。

### 1.2 交付给用户的不是这个目录

交付的是 **signed bundle**：一份**清单**（说明包里有哪些文件、各自多大、哈希是多少）+ 这些
文件的字节 + 一份**分离式签名**。清单叫 **envelope**，它才是被签名的那个对象。

```jsonc
// envelope —— 被签名的对象。小、可读，签名者可以逐行读完再按下硬件令牌
{
  "bundleFormat": "elecon-bundle/3",
  "adapterId": "school-yourschool",
  "adapterVersion": "0.1.0",
  "files": [
    { "path": "index.js",      "size": 4211, "sha256": "9f2c…" },
    { "path": "manifest.json", "size":  812, "sha256": "3ab0…" },
    { "path": "masker.json",   "size":  147, "sha256": "c751…" }
  ]
}
```

上线时它被装进一个 gzip 的 JSON 里，和签名、以及**按哈希寻址**的文件字节表放在一起：

```jsonc
gzip(JSON({
  "envelopeB64": "<上面那个 envelope 的字节，base64>",
  "signature":   { adapterId, adapterVersion, tier, digest, signature, keyId, algorithm },
  "blobs":       { "9f2c…": "<index.js 的字节，base64>", "3ab0…": "…", "c751…": "…" }
}))
```

**为什么文件字节按哈希存、不按路径存**：这样「哪个路径对应哪份内容」这件事**只**由被签名的
envelope 说了算，传输层动不了手脚。gzip 在签名之外，只管压缩。

> **历史**：上一代格式 `elecon-bundle/1` 把文件内容直接内联进 envelope，且 digest 的算法**不覆盖
> 路径**——于是一次**保序重命名**就能在 digest 不变的前提下换掉被执行的入口。v2 的动机与规格见
> [`adr_018`](../adr/adr_018_adapter_distribution.md) §2.9.1。这次改动对你写 adapter 没有影响——
> 变的是打包与验签，不是你写的文件。

### 1.3 digest 是什么

`digest = SHA-256(envelope 的字节)`。一个 64 位十六进制串。它是这个包的**身份证**：

- catalog 用它索引版本，客户端用它做缓存 key；
- 它**就是下载路径**：客户端按自己配置的分发地址拼 `bundles/<digest>.json.gz` 去拉——catalog 里**没有 URL**，
  所以同一份签名产物可以放官方端点、镜像、或维护者本机，不用重签；
- 签名签的就是它（连同 `adapterId` / `adapterVersion` / `tier` 一起）；
- **任何人都能独立复算**——这一点很重要，见 §2 的「签名维护者」。

---

## 2. 每个角色看到什么、能做什么

链条一共五段。**注意每一段能拿到的东西都比上一段少或不同**——这不是流程繁琐，这是设计。

```
  你（贡献者）          CI（门 1）        审查沙箱（门 2）      签名维护者        分发 / 客户端
       │                   │                   │                   │                   │
   写目录 ────PR───▶  静态检查 ────────▶  容器内实跑 ────────▶  离线签名 ────────▶  验签后加载
       │                   │                   │                   │                   │
  无私钥            无签名能力          仅测试账号           持硬件令牌         只信预埋公钥
                                       无生产密钥          不接网络
```

### 2.1 你（外部贡献者）

**看得到**：你自己的目录、契约 schema、validator/scanner 的报错、模板与 helloworld 示例。

**能做**：写 manifest 与代码；跑本地校验；提 PR。

```bash
# 结构与契约校验（ajv + 项目规则）
cd tools && npm run validate -- --adapter=../adapters/school-yourschool

# 夹具里的 PII / 凭证等价物扫描（红线 #1/#8，硬门）
cd tools && npm run scan -- --path=../adapters/school-yourschool

# 自己算 digest（无密钥，纯确定性）
cd tools && npx tsx src/signer/index.ts digest --adapter=../adapters/school-yourschool
```

**拿不到**：
- **任何私钥**。签名不在任何自动化里，公开仓库的 CI 没有签名能力。
- **任何用户凭证的值**。你在 `manifest.credentials` 里声明的是 `ref`（引用名）和注入 scope；
  真正的 cookie/token 只存在于可信核心，由 broker 在出网那一刻注入。你的代码看不到它，
  日志里也不会有它。这是红线 #1，没有例外，DEV 环境也一样。
- **直接出网的能力**。你声明 `network.allow`，由核心代表你发请求。

**别做**：提交真实学生数据（夹具必须脱敏，扫描器是写后硬门）；在 fixtures 里留 Cookie /
`Set-Cookie` / 带 token 的 URL。

### 2.2 CI（门 1，公开仓库）

**看得到**：你的 PR 内容。**能做**：schema 校验、编译检查、import 白名单、PII/凭证等价物扫描、
digest 预检（只算不签）。**没有**：任何签名能力、任何生产密钥。

CI 绿 ≠ 会被签名。它只说明「结构上没毛病」。

### 2.3 审查/打包沙箱（门 2，构建期）

**看得到**：你的代码，并在**容器内实际运行**它做行为与性能验证。**用的是测试账号**，走的仍是
broker 注入——即便在这里，adapter 也看不到凭证的值。**没有**：生产签名密钥。

产出：**未签名的 bundle + digest**。这个 digest 是下一步的比对基线。

### 2.4 签名维护者（离线）

**看得到**：门 2 产出的未签名 bundle，和它自己在离线机上**重算一遍**的 digest。

**做的事**：确认两个 digest 一致 → 用 YubiKey（PIN + **物理触碰**）对
`{adapterId, adapterVersion, tier=official, digest}` 签一个 Ed25519 签名 → 落 `signature.json`。

**为什么要重算**：这一步是防「所见非所签」的唯一防线——如果签名机被攻陷，它可以在你按下触碰的
瞬间替换掉待签内容。重算 digest 并比对是唯一能发现这件事的动作。也正因为如此，被签名的 envelope
被刻意设计得**小到可以人眼读完**（这就是 §1.2 里文件字节不内联进 envelope 的原因之一）。

**签 official 是一个需要显式人工批准的动作**，不能被任何脚本代劳。私钥在硬件里生成、从不导出、
不进仓库、不上任何服务器。

### 2.5 分发与客户端

CDN / 公网哑服务只是搬运字节，**零凭证、无状态**。它托管三样东西：签名的 catalog、签名的吊销清单、
按 digest 命名的 bundle 文件。客户端持有分发地址，catalog 只告诉它「有哪些 digest」。

客户端核心拿到字节后，按固定顺序 fail-closed 地检查（任一步失败即拒绝加载，不降级、不放行）：

| # | 检查 |
|---|---|
| 1 | 大小上限 → 有界解压（压缩炸弹护栏） |
| 2 | 只解析最外层的**传输封套** |
| 3 | 取出 envelope 字节 |
| 4 | 算法必须是 ed25519；`keyId` 必须命中**编译进 App 的** active 公钥 |
| 5 | 重算 `SHA-256(envelope 字节)`，比对签名声明的 digest |
| 6 | Ed25519 验签 —— **到这里为止还没解析过 envelope 的内容** |
| 7 | 才解析 envelope；`bundleFormat` 必须严格相等 |
| 8 | 路径卫生：重复路径、绝对路径、`..`、反斜杠、空路径等一律拒 |
| 9 | 文件字节表必须与清单**一一对应**（多一个、少一个都拒） |
| 10 | 逐文件：长度对得上、哈希对得上 |
| 11 | 身份三方一致：签名 ↔ envelope ↔ `manifest.json` |
| 12 | stdlib 版本门 → 吊销清单 → 交给 QuickJS 执行 |

信任根是**编译进 App 二进制**的一组公钥。任何下发的数据（catalog、吊销清单、服务端应答）
都**无法**引入一把不在二进制里的新公钥——换句话说，更新通道不能变成新的信任入口。

---

## 3. 常见误解

**「我在 manifest 里写 `trustTier: official` 就是 official 包了。」**
不是。那个字段是**声明**，不是依据。真正的档位来自签名——核心验不到对应签名就直接拒。
（它在签发期另有用途：validator 用它把某些敏感能力限制在 official 意图之内。）

**「签名说明这个 adapter 是安全的。」**
签名说明的是「这些**字节**确实是官方审查并批准过的」。它不证明代码没 bug，也不给 adapter
任何额外权限——出网范围、凭证注入 scope 仍由 manifest 声明 + 核心 enforce。

**「我改个注释应该不用重新走流程吧。」**
要。进包文件的任何一个字节变了，digest 就变了，旧签名对新 digest 无效。这是内容寻址的
必然结果，不是流程刻意为难。

**「catalog 里写了版本和 stdlibMin，那以 catalog 为准。」**
不。catalog 里那些字段只是**预下载提示**。权威值在 bundle 内的 `manifest.json`，
因为它在签名覆盖范围内。

**「catalog 里应该写包的下载地址吧。」**
不写。catalog 只描述**文件**（digest、版本、能力），不描述**端点**；地址由客户端自持。
这样换域名、上镜像都不用重签（ADR-018 §2.5.1）。你在 sequence ≤ 8 的老 catalog 里看到的 `url` 是已弃用字段。

**「fixtures 会被一起分发，所以要写得像生产数据。」**
恰恰相反。fixtures 不进交付包，且**必须脱敏**——扫描器是硬门，真实学生数据不得提交。

**「DEV 模式下 adapter 能看到凭证值吧？」**
不能。DEV 允许加载未签名 adapter、允许用开发者测试凭证，但**凭证值仍不离开核心**。
DEV 与 DEPLOY 的区别在「能不能加载未签名的东西」，不在「能不能看到密码」。

---

## 4. 接下来读什么

| 你想知道 | 去读 |
|---|---|
| manifest 每个字段什么意思 | [`contract/manifest.schema.json`](../../contract/manifest.schema.json)、[`adr_001`](../adr/adr_001_contract.md) |
| 新功能怎么加、什么时候需要 ADR | [`docs/rules/feature_workflow.md`](../rules/feature_workflow.md) |
| 分支、commit、PR 规范 | [`docs/rules/git.md`](../rules/git.md) |
| 测试怎么写 | [`docs/rules/testing.md`](../rules/testing.md) |
| 信任模型的完整论证 | [`adr_002`](../adr/adr_002_trust_model.md) |
| 分发链路与包格式的完整规格 | [`adr_018`](../adr/adr_018_adapter_distribution.md) |
| 凭证引用怎么声明 | [`adr_013`](../adr/adr_013_manifest_credentials.md) |
| 签名仪式细节（维护者用） | [`signing_ceremony.md`](./signing_ceremony.md) |
