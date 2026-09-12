# 发版跨仓协商清单（seq 9 已完成 · `/3` masker 仪式待做）

> 2026-09-12 起草。目的：把「核心仓 `elecon`」与「社区仓 `elecon-adapters`（A 仓）」在下一次签名仪式前各自要做的事
> 摆在一页上，做完打勾。**不是 ADR**；判据引用 ADR-018 §2.5.1 / §2.9.1、ADR-026 §2.7.1、整改清单 §2.8 / §2.9。
> 状态只认两处：决策看 `docs/adr/README.md`，执行看 `2026_08_review_remediation.md`；本页是这两处之间的工作单。

## 0. 这次发版是什么、不是什么

| | 内容 |
|---|---|
| **是** | `elecon-bundle/2` 仪式：catalog **seq 9**、revocation **seq 3（TTL 180 天）**；catalog 自此不写 `url`；采用 A 仓最新源 |
| **不是** | masker `/3` 断代仪式（seq 9 当时 RM0 仍无条件拒签带 `masker.json` 的 adapter）。**`/3` 的代码已于 2026-09-12 随后落地，仪式本身见下方 §6** |
| **动机** | ① **入库 bootstrap** 的 revocation seq 2 于 2026-09-18T06:31Z 过期，之后 `release.yml` 的 G2 硬失败、无法出任何 app 版本；② catalog 去端点化后，入库 seq 8 的 catalog 仍带 `url`，签一份干净的才能删字段 |
| **端点 D 现状** | 公网端点暂不可用（整改清单 §2.8；2026-09-12 实测不可达），seq 8/2 从未上传，线上若有产物也至多是 7 月的 seq 3/1。故 §3 末尾的 G6 `--online-base=` 只在端点恢复后跑；端点未恢复时**省略该步**（G6 拉不到即 error，不是 warn） |

## 1. 核心仓（elecon）前置

| # | 事项 | 状态 |
|---|---|---|
| 1 | 合并 PR #115（仪式 + 去端点化 + bootstrap 单源）、#116（P3-08 发版门 + TTL 180 天预备） | [x] 已合并（main `d28bdd9`）；ADR-018 §2.5.1 实现 owner 2026-09-12 签收（整改清单 §2.8） |
| 2 | 镜像到 A 仓：`node scripts/mirror-to-adapters-repo.mjs`（vendor 的 `catalog.schema.json` 变为 `url` 可选、validator 带 K3） | [x] A 仓 `d22f167`（core@59bdbae；此后 core 只改了 `release/` 与 gate，不在镜像面内，无需重跑） |
| 3 | A 仓改完后 bump `adapters.pin` 到其新 commit，CI 绿 | [x] pin → A 仓 `cc18b1f`（2026-09-12）；CI 绿待 PR |
| 4 | 仪式当天：`release/revocation.json` 只刷新 `issuedAt`（seq 3 / ttl 15552000 已预备；改内容须 bump，见 G5） | [ ] |

## 2. A 仓（elecon-adapters）需要添加 / 修改

| # | 事项 | 为什么 | 状态 |
|---|---|---|---|
| A1 | `scripts/catalog.mjs`：**不再写 `url`**，去掉 `CATALOG_BASE_URL` 硬要求；`--check` 见残留 `url` 告警（对齐核心 K3） | ADR-018 §2.5.1：catalog 只描述文件；vendor 同步后 `catalog:check` 会见到 `url` 已弃用 | [x] 2026-09-12 已改、`npm run check` 全绿；A 仓 `cc18b1f` 已推送 |
| A2 | **版本 bump 只给字节变了的 adapter**：本次若某 adapter 源未动，`adapterVersion` **不要**动 | 台账身份 = `adapterId+adapterVersion` = 一份字节，只记一次；未变字节沿用 seq 8 的记录，发版门 G4 放行。上次全 bump 是因 v1→v2 每份字节都变了 | [x] 核对：A 仓 `adapters/` 自 pin `444b92c` 起**零改动**，5 份 digest 将与 seq 8 完全相同，本次**不 bump、台账不新增记录** |
| A3 | （可选，不阻塞）`school-thu` / `school-xidian` 的 `grades.list` 产出补 `gradePointScale` + `gradePointSource: "source"`；改了就 bump patch | `gradepoint_ownership_landing.md` §4.1；尺度须人工确认（西电 4.3？清华？），**不确认则客户端 GPA 保持不显示**（fail-closed） | [ ] 待人工事实 |
| A4 | **不要加** `masker.json` | 见 §0；加了签不出来 | — |
| A5 | 收到 vendor 镜像后 `npm run check` 全绿（validate / scan / compile / catalog:check） | 门 1 | [ ] |

之前记在整改清单 §2.4 的三处同步项（路径段白名单、`BUNDLE_EXCLUDE` 大小写、`/1` 时代过时提示）**核对已全部完成**（A 仓 `444b92c`），不再列。

## 3. 仪式当天（核心仓，持 YubiKey 的人）

```bash
# 前置：签的就是核心 CI 测过的那份源——本地 A 仓须干净且 HEAD == adapters.pin
cd ~/projects/elecon-adapters && git status --short && [ "$(git rev-parse HEAD)" = "$(grep -vE '^\s*(#|$)' ~/projects/elecon/adapters.pin)" ] && echo pin-ok
cd ~/projects/elecon-adapters && npm run check && npm run bundle           # A 域产物 + sha256
cd ~/projects/elecon/tools
npx tsx src/signer/index.ts digest --adapter=../../elecon-adapters/adapters/<每一份>   # 签前重算，与 A 逐字比对（§3 所见即所签）
npm run release:package -- --adapters=../../elecon-adapters/adapters --out=../dist-9 \
  --revocation=../release/revocation.json --sequence=9 --key-id=elecon-official-ncc-1 \
  --pkcs11-module=/usr/lib/libykcs11.so --serial=<序列号> --pinentry-command=/usr/bin/pinentry-qt
#   ↑ 打包器会按入库 bootstrap 基线拒：--sequence ≤ 8、revocation 倒退、同序号改内容
npm run bootstrap:sync -- --dist=../dist-9 && npm run bootstrap:verify
# 台账：仅当本次有 bump 过的 adapter 才做（A2 核对为零改动 → 本步整体跳过，G4 沿用 seq 8 记录）。
# extract 从仓根跑、--dist 相对仓根、输出到 stdout（不自动追加）；把其中**新身份**的记录手工追加进
# release/adapter-release-ledger.json，未变身份的记录丢弃（重复身份会被 validate 判 equivocation）。
( cd .. && npm run ledger:extract -w tools -- --dist=dist-9 --key-id=… --public-key-hex=… \
    --source-commit=… --signed-at=… --signer=… --review-reference=… > /tmp/ledger-draft.json )
npm run ledger:validate && npm run release:gate            # G1–G5 全过
git add ../client/assets/bootstrap ../release && git commit  # bootstrap 是唯一入库产物；dist-9 不入库
npm run dist:export && <上传 ../dist-export 到端点 D>        # 端点 D 未恢复则此步与下一步顺延
npm run release:gate -- --online-base=https://elecon.xidian.one/adapters/   # G6：线上 = bootstrap（端点可达才跑）
```

> **本次仪式在台账里没有痕迹**：台账按 adapter 身份记账，catalog / revocation 本身的签发（seq 9 / 3）只体现在
> 入库 bootstrap 的 git 历史里。这是 P0-15 的已知边界，不是遗漏；若要有仪式级记录，另立议题、不在本次。

`--adapters=` 必须指向含全部 5 个 official 目录的同一个根（A 仓 `adapters/`），否则线上 catalog 会缩成单条。

## 4. 仪式之后（核心仓 follow-up PR）

> 仪式已于 2026-09-12T06:19Z 执行（seq 9 / 3，五份 digest 未变，门全绿），记录见整改清单 §2.10。

| # | 事项 | 状态 |
|---|---|---|
| 0 | 仪式收尾 PR：bootstrap seq 9/3 入库、`adapters.pin` → `cc18b1f`、`git rm --cached dist-full`（此前实际仍被跟踪）、文档同步 | [x] 分支 `chore/ceremony-seq9-followup` |
| 1 | 删 `url`：`contract/catalog.schema.json` 移除字段、`catalog.dart` 容忍集去掉 `'url'`、validator 去掉 K3；`contract/CHANGELOG.md` 记一条（ADR-018 §2.5.1 已预告） | [x] 分支 `refactor/catalog-drop-url`（基于 0），待 PR |
| 2 | 整改清单新增执行状态节：seq 9 / 3 参数、台账变化、线上生效时间 | [x] §2.10 |
| 3 | A 仓 mirror：`mirror-adapters.yml` 在 main 的 `contract/**` 变化时**自动**推 vendor，无需手跑；镜像提交出现后 bump `adapters.pin`，并顺手删 A 仓 `catalog.mjs` 里已成死代码的 url 告警分支（schema 拒绝在前） | [ ] 待 1 合并 |
| 4 | 端点 D **2026-09-25** 恢复后：`npm run dist:export -w tools` 上传，`release:gate -- --online-base=…` 跑 G6 | [ ] 此前真机测试用本地端点（DEV base 覆盖） |

## 5. 明确不在 seq 9 本次

- ~~masker `/3` 断代 + RM0 移除 + loader 接线~~ → **代码已于 2026-09-12 落地**（整改清单 §2.11），仪式见 §6
- 第二把签名密钥（ADR-002 §3 风险 2(c)，已知缺口）
- 新学校 / 新 capability

## 6. 下一次仪式：`elecon-bundle/3` masker 断代（catalog seq 10）

> 前置代码已全部合入（ADR-026 §2.7.1 / §2.7.2，整改清单 §2.11）。**在本仪式完成前，
> `npm run bootstrap:verify -w tools` 必然失败**——入库 bootstrap 还是 `/2` 签名产物，新 host 按严格相等
> 拒载它。这是断代的预期代价，也是「不忘记仪式」的硬门，刻意不消。`client/test/school_manifest_test.dart`
> 显式 skip，`release:gate` 不解析 envelope、此期间仍通过。

### 6.1 本次与 seq 9 的差别

| | 内容 |
|---|---|
| **格式** | `elecon-bundle/3`（envelope 结构不变；断代只表达「official 必带 `masker.json`」） |
| **catalog** | **seq 10**（5 份 digest **全变**——每份都多了 `masker.json`） |
| **revocation** | seq 3 沿用即可（TTL 180 天，2027-03-11 到期）。**只有改内容才 bump**，见 G5 |
| **版本** | 5 份**全部 bump**：fudan/helloworld/thu/xjt `0.1.1 → 0.2.0`、xidian `0.4.1 → 0.5.0`（A 仓已改） |
| **台账** | **新增 5 条**——身份 = `adapterId+adapterVersion`，5 个都是新身份，G4 要求每个都有首签记录 |

### 6.2 前置核对

| # | 事项 | 状态 |
|---|---|---|
| 1 | A 仓补 5 份 `masker.json` + bump 版本 + `build-bundle.mjs` 切 `/3` + vendor 镜像 | [ ] 已改待提交（见 §6.5） |
| 2 | 核心 `adapters.pin` → A 仓该提交 | [ ] 待 1 |
| 3 | 核心 masker 落地 PR 合并、CI 绿（除 §6 首段两处已知红） | [ ] |

### 6.3 仪式当天（持 YubiKey 的人）

```bash
# 前置：本地 A 仓干净且 HEAD == adapters.pin
cd ~/projects/elecon-adapters && git status --short && [ "$(git rev-parse HEAD)" = "$(grep -vE '^\s*(#|$)' ~/projects/elecon/adapters.pin)" ] && echo pin-ok
cd ~/projects/elecon-adapters && npm run check                      # validate 须 5/5 过（含 RM0_policy_missing 不触发）
for a in fudan helloworld thu xidian xjt; do npm run bundle -- --adapter=school-$a; done
cd ~/projects/elecon/tools
for a in fudan helloworld thu xidian xjt; do \
  npx tsx src/signer/index.ts digest --adapter=../../elecon-adapters/adapters/school-$a; done
#   ↑ 逐份与 A 域 .sha256 比对（§3 所见即所签）。2026-09-12 预演值：
#     fudan 6284168401c7… helloworld e7db14c1c9f9… thu aceb211147fb… xidian 7af3008928c8… xjt 3c5eaa2341b9…
npm run release:package -- --adapters=../../elecon-adapters/adapters --out=../dist-10 \
  --revocation=../release/revocation.json --sequence=10 --key-id=elecon-official-ncc-1 \
  --pkcs11-module=/usr/lib/libykcs11.so --serial=<序列号> --pinentry-command=/usr/bin/pinentry-qt
npm run bootstrap:sync -- --dist=../dist-10 && npm run bootstrap:verify   # 此时才会转绿
# 台账：本次**每一份都是新身份**，5 条全要记。extract 从仓根跑、--dist 相对仓根、输出到 stdout。
( cd .. && npm run ledger:extract -w tools -- --dist=dist-10 --key-id=… --public-key-hex=… \
    --source-commit=<A 仓 masker 提交> --signed-at=… --signer=… --review-reference=… > /tmp/ledger-draft.json )
#   把 5 条全部追加进 release/adapter-release-ledger.json
npm run ledger:validate && npm run release:gate                      # G1–G5 全过
cd .. && npm run test -w client -- test/school_manifest_test.dart     # 断代后这条应转绿
git add client/assets/bootstrap release && git commit                 # bootstrap 是唯一入库产物
npm run dist:export -w tools && <上传 dist-export 到端点 D>            # 端点 D 2026-09-25 后
npm run release:gate -w tools -- --online-base=https://elecon.xidian.one/adapters/   # G6
```

### 6.4 仪式后

- 整改清单 §2.11「仍开」①②消项；P0-09 / P0-10 转入 owner 逐行安全复签（清单
  [`response_masker_signoff_checklist.md`](../reference/response_masker_signoff_checklist.md)）。
- `docs/adr/README.md` 的 026 行去掉「余一次 `/3` 重签仪式」。

### 6.5 A 仓待提交内容（2026-09-12 已改好，等 GPG 签名）

5 份 `masker.json`（空规则）+ 5 份 manifest 版本 bump + `scripts/build-bundle.mjs` 切 `/3` +
`scripts/catalog.mjs` 删已成死代码的 url 告警 + vendor 镜像（新 golden、新 validator）。
`npm run check` 全绿，5 份 digest 与核心 signer 逐字一致。
