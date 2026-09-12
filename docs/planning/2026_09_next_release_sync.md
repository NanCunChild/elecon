# 下一次发版（catalog seq 9）· 跨仓协商清单

> 2026-09-12 起草。目的：把「核心仓 `elecon`」与「社区仓 `elecon-adapters`（A 仓）」在下一次签名仪式前各自要做的事
> 摆在一页上，做完打勾。**不是 ADR**；判据引用 ADR-018 §2.5.1 / §2.9.1、ADR-026 §2.7.1、整改清单 §2.8 / §2.9。
> 状态只认两处：决策看 `docs/adr/README.md`，执行看 `2026_08_review_remediation.md`；本页是这两处之间的工作单。

## 0. 这次发版是什么、不是什么

| | 内容 |
|---|---|
| **是** | `elecon-bundle/2` 仪式：catalog **seq 9**、revocation **seq 3（TTL 180 天）**；catalog 自此不写 `url`；采用 A 仓最新源 |
| **不是** | masker `/3` 断代仪式。`RM0_host_gate_unavailable` 仍无条件拒签带 `masker.json` 的 adapter，loader 门未接线（P0-09 / P0-10）。**A 仓本次不要加 `masker.json`** |
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

## 5. 明确不在本次

- masker `/3` 断代 + RM0 移除 + loader 接线（ADR-026 §2.7.1，随 P0-09 / P0-10）
- 第二把签名密钥（ADR-002 §3 风险 2(c)，已知缺口）
- 新学校 / 新 capability
