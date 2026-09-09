# 归档：bundle digest v1 规格与 v1→v2 的决策过程（2026-09-01）

- **文档性质**：被取代的规格 + 决策过程记录（只读档案）
- **归档日期**：2026-09-09
- **决策权威**：[`adr_002`](../adr/adr_002_trust_model.md) §2.3（签什么、配套纪律）与
  [`adr_018`](../adr/adr_018_adapter_distribution.md) §2.9.1（上线形态、验证顺序）。
  **本文不是决策源**，与两处 ADR 冲突时以 ADR 为准。
- **落地状态**：见 [`adr/README.md`](../adr/README.md) 与
  [`2026_08_review_remediation.md`](../planning/2026_08_review_remediation.md) P0-01。**本文不记录状态。**

> **为什么单独归档**：v1 规格已被 v2 取代，v1→v2 的论证过程（为何不选四元组 / Merkle / 签压缩包 /
> 内联 base64）在 ADR 正文里占了将近一半篇幅，但读者要执行的只有 v2 规格与配套纪律。
> 把论证抽到这里，ADR §2.3 只留「签什么 + 必须守什么」。**论证本身不能删**——它挡的是
> 「换个人、隔半年，把同一个被否掉的方案重新提一遍」，所以逐条保留在此，ADR 正文各处留一行指路。
>
> **术语**：本文所称 envelope / 信封一律指 **bundle 信封**（ADR-000 §2.3.1）。

---

## 1. 被取代的规格（digest v1）

```
digest = SHA-256( SHA-256(file1) ‖ SHA-256(file2) ‖ … )      // 文件按相对路径字典序
```

**缺陷**：**路径只参与排序、自身从不进哈希**，`encoding`、文件个数与 `bundleFormat` 亦然。
于是任何**保持字典序位次的重命名**都不改变 digest——而加载器恰恰是**按路径**取要执行的字节
（`manifest.runtime.entry`，以及 [`adr_026`](../adr/adr_026_response_masker.md) 的 `masker.json`）：

```
签名时（受审目录，无害）              伪造后（一个内容字节都没改，只改名）
────────────────────────              ──────────────────────────────────
1  assets/theme.css → EVIL            1  index.js      → EVIL   ← 被执行
2  index.js         → BENIGN          2  index.js0     → BENIGN
3  manifest.json    → MANIFEST        3  manifest.json → MANIFEST
```

两侧「按路径排序后的内容序列」都是 `[EVIL, BENIGN, MANIFEST]`，digest 逐字节相同（实测
`c3bc2557…ab21`）。official 签名验过、身份核对（ADR-002 §2.2）通过、stdlibMin 门通过。
攻击者 = ADR-018 信任域 A 的社区贡献者或任何能把内容放进受审 bundle 的人；**人工审查看到的是
无害目录，检出率为零**。直接击穿红线 #4。

可执行证据：`tools/src/bundle/path-binding.redcase.ts` A 组（两侧 digest 逐字节相同）。

**病根**：旧 envelope 一个人干了三件事——**容器**（装文件字节）、**清单**（声明有哪些文件）、
**签名对象**。「清单」被「容器」吞掉，唯一没被签的字段恰是 `path`。v2 的全部动作就是把容器拆出去，
让 envelope 只做「清单 + 签名对象」。

---

## 2. 被否掉的备选与理由

### 2.1 四元组叶子编码（`path + encoding + length + content`）

在每个文件的叶子哈希里显式拼进路径与长度，仍保持 Merkle 式双层结构。

**否决理由**：envelope 本身已是一份确定性序列化文档，直接哈希其字节即可让路径 / 编码 / 顺序 /
个数 / `bundleFormat` 全部落入签名范围，**无需在 TS 与 Dart 各写一份叶子编码器并靠 golden 维持
一致**。这与 ADR-018 §2.5 给 catalog 定的「字节精确、不重新规范化序列化」是同一取向——bundle
此前未遵守该结论，v2 是把它补上，不是发明新东西。

### 2.2 Merkle 树 / 逐文件绑定

**否决理由**：Merkle 的正当收益是**部分取用 / 逐文件验证 / 去重 / 增量更新**。elecon 当时一条
都用不上——整包取用、按 digest 整包缓存、单包 ≤ 256 KiB。为用不上的收益付两端叶子编码器的
一致性成本，不划算。

> **⚠️ 该前提有保质期**：三条「用不上」全部依赖「单包小、整包取用」。若 adapter 开始携带大体积
> 运行时资产（模型权重、字典、图片集），部分取用与去重就变成真需求。**但这不构成翻案理由**——
> v2 的 descriptor 形态（`files[].sha256` + 内容寻址 blob 表）已经是「清单 + 内容寻址」，
> 逐文件绑定的收益它本来就有；届时要加的是**传输与落盘的分片**，不是改回 Merkle、更不是改 digest。
> 见 ADR-018 §2.9.1「大体积资产的前向兼容」。

### 2.3 签压缩包字节（APK v2 式单段连续字节）

**否决理由**：方向对、落点错。gzip 输出不确定（压缩级别、header 的 OS 字节 / mtime、zlib 版本），
签压缩字节会**废掉 ADR-018 §3 风险 (e)「所见非所签」的唯一防线**——维护者在离线签名机上重算
digest 并与审查沙箱产物比对；也使 P0-15 台账无法从 source commit 复算 digest。
故取**未压缩的 envelope 字节**：同样是单段连续字节，但可从 git checkout 复现。

若「包」指 tar/zip，则等于把自研归档解析器塞回 🔒 Dart 加载器，正是当初弃 tar 的理由。

### 2.4 把内容内联进签名对象（v2 早期形态）

即 `files: [{ path, encoding, content }]`，content 为 base64 文本，整个对象即被签字节。

**否决理由三条**：

1. **编码离开信任边界（安全论据，非整洁论据）。** 内联方案里 base64 文本**就是被签的字节**，
   两端各自解码它；而两端解码器行为实测不同——`Qh==`（尾位非零）、`QQ`/`QQ=`（填充错）、
   含空白的 base64，Node `Buffer.from` 全部宽松接受并产出字节，Dart `base64.decode` 全部抛。
   一份签名合法的 envelope 会在 Node 侧（validator / 审查沙箱 / 台账提取）被接受并审阅，在 Dart
   客户端被拒。方向是 fail-closed 而非提权，但足以签出「某些端装不上」的产物，并迫使契约额外
   规定「必须规范 base64」。descriptor 方案下内容是**内容寻址**的：解码器无论宽严，产出字节都
   必须命中 `sha256`，对不上即拒——编码差异从**信任问题**降级为**传输问题**。
2. **签名对象变成人可审的小对象。** §3 风险 (e)「所见非所签」的唯一防线是离线机重算 digest 比对。
   内联方案下待签对象是几百 KB 夹满 base64 的 JSON，那条防线名义存在、实际无法执行；descriptor
   方案下它是十行，签名者可以逐行读完再按触碰。**这是本次修订最实在的收益。**
3. **台账可记录 envelope 全文**，P0-15 的 `sourceCommit ↔ bundleDigest` 对账因此落到逐文件粒度。

**代价**（已接受）：新增「blob 集合精确相等」不变量——少一个会被逐文件校验抓到，**多一个不会**，
必须显式拒绝。这是 v2 唯一新增的、可以搞砸的地方，四个负例须双端 golden 钉死。

---

## 3. 两处改判的理由

### 3.1 规范化：从「哈希前静默改写」改为「构建期检查、不符即拒签」

LF/NFC 等规则**内容不变**，只是执行位置从哈希前的静默改写移到 `buildEnvelope` 的构建期检查。

**改判理由**：原先「签规范化后的字节」使多份不同的磁盘文件映射到同一 digest，签名因此**不唯一
标识磁盘上的真实字节**，也迫使 🔒 Dart 加载器必须论证自己为何不做 NFC。改为「拒绝而非改写」后，
签名与磁盘字节一一对应，Dart 侧不引入任何 Unicode 规范化实现。

### 3.2 身份核对：从两方改为三方

envelope 顶层新增 `adapterId/adapterVersion` 是**一处冗余**（权威值在 `manifest.json`，已进 digest）。

**为何仍要加**：换来「人眼审的那个对象自述它是哪个 adapter」——否则 §2.4 收益 2（签名对象可人眼
审完）被削掉一半：审的人看得见文件哈希，却看不出这是谁的包。
`manifest.json` 仍是运行时策略（`network.allow` / `credentials` / `runtime.entry`）的唯一权威源，
envelope 顶层身份**只用于核对，不用于裁定**。

---

## 4. 域分隔：修订前的现状

v2 之前，official 密钥同时签三类对象——bundle 载荷、catalog 原始字节、revocation 原始字节——
而三者**没有任何显式域分隔**，只靠「JSON 形状恰好互不满足对方 schema」偶然隔开
（`serializePayload` 的输出缺 `catalogVersion/sequence`，故过不了 catalog 校验，反之亦然）。

这是**偶然的隔离，不是设计出来的**；第四个签名对象出现时（传输底座二进制、policy pack、
bootstrap 清单）随时可能撞上。v2 的 `contextTag ‖ 0x00 ‖ 被签字节` 规则即为此而设。

---

## 5. 迁移事实核实（2026-09-01）

`records` 为空是 **P0-15 台账未建立**，不等于未签发。核实结果：实存 **7 份 official 签名 bundle**
（`dist-full/` `dist-xidian/` `dist-helloworld/`，其中 5 份随包在 `client/assets/bootstrap/`）
+ 已签名 catalog（sequence 3）+ revocation，全部由 `elecon-official-ncc-1` 真机签发。

**无外部持有者** → 不设双读、不新增 host version gate、`/1` 路径整体删除（旧端由既有
`bundleFormat` 相等判断自动拒载）。

**暴露面：潜伏但尚未武装。** 攻击充要条件 = 「在 `manifest.json` 字典序**同一侧**存在 ≥2 个文件，
且至少一个不按固定路径查找」——按固定路径查找的文件各钉死一个位次，位次全钉死则重命名无自由度。
现存 7 份 bundle 的 `files` **全为 `[index.js, manifest.json]`** → 不可利用；补 `masker.json` 后
三者分居三个固定位次 → 仍不可利用。**暴露面在第一份携带运行时资产的 bundle 出现时打开。**
故不需紧急吊销，但须在 adapter 开始携带资产前落地。
