# Elecon · 校园信息聚合平台

一个面向学生的校园信息聚合应用。它把成绩、课表、一卡通、图书馆等分散在不同学校后端的信息，归一化后聚合到一处。架构的第一目标不是功能最大化，而是**在最少的人力下，对学校接口的频繁变动与多平台差异保持韧性**。

---

## 它解决什么

- **学校接口频繁变动** → 把对接逻辑沉成可热替换的 adapter，接口一改推新 adapter 即可，**无需发版**。
- **维护人力不足 / 社区难参与** → 贡献者使用普通异步 JavaScript 编写 adapter，只面向一套全平台客户端 runtime。
- **合规与安全** → 私密数据只在用户设备侧经 direct、系统 VPN 或 official transport 访问学校，**项目服务端不持有任何凭证**。
- **多平台割裂（iOS / Android / HarmonyOS）** → 保留 Flutter UI，传输/数据/UI 三层各自可替换。

---

## 架构速览

```
        UI 层（数据驱动 / SDUI，只认"标准 schema"）
                       │
        可信宿主 —— 执行准入 · QuickJS · Credential Store · 网络出口
            │                                   │
   数据 adapter（QuickJS 脚本，热替换）    传输底座（原生，仅官方签名）
            │                                   │
             │                                   │
       学校 origin                         公网哑服务 public
  direct / VPN / app-tunnel          静态分发 adapter/catalog
                                         零凭证、不执行 adapter
```

**两条要记住的原则：**

1. **客户端是唯一生产执行面**——adapter 在全平台共用的客户端 QuickJS/host API 中运行；项目不提供校内中继。
2. **公网服务端是静态分发面**——不执行 adapter、不持凭证或私密数据。fixture 回归保留，但不再维护客户端/服务端 runtime 一致性 golden。

完整路线与取舍见 [`docs/adr/adr_000_abstract.md`](docs/adr/adr_000_abstract.md)；目录与职责见下方[「仓库结构」](#仓库结构)与各子目录的 `README.md`，开发总则见 [`AGENTS.md`](AGENTS.md)。

---

## 仓库结构

```
contract/   V2 契约：标准 schema + capability manifest + adapter SDK + wire/security 向量
adapters/   仅核心自带 adapter：_stdlib（vendored 解析器）/ _template / _canary / school-helloworld。
            真实学校 adapter 已迁出到独立公开仓 elecon-adapters，构建期按 adapters.pin 钉死的 ref
            拉取（scripts/fetch-adapters.sh，ADR-018 §2.11.1，取代旧 git 子模块）。
adapters_tests/  各校抓包探针与脱敏夹具（红线 #8：不含真实学生数据/凭证）。
client/     Flutter 客户端（iOS / Android / HarmonyOS / 桌面）
server/     Node/TS 公网静态分发服务 + V1 迁移期/审核辅助工具；不执行产品 adapter
tools/      Node/TS 工具链：签名（PKCS#11 / YubiKey）/ 吊销 / adapter 校验 / 契约一致性 / codegen
docs/       ADR、规则细则（docs/rules/）与工程结构说明
```

---

## 构建与运行

### 客户端（Flutter）

```bash
cd client
flutter pub get
flutter run                 # Android / 非 Apple 桌面
bash tool/with_apple_pubspec.sh flutter run --target lib/main_apple.dart  # iOS / macOS
```

**HarmonyOS：** 用 FVM 管理多版本 SDK，平时用官方版保持主线纯净，仅在打包鸿蒙时切到 OHOS 分支 SDK；鸿蒙特有依赖只写入 `client/pubspec.ohos.yaml`，由 `tools/ohos/build-hap.sh` 临时启用。详见 `client/ohos/README`。

### 服务端（Node / TypeScript）

```bash
cd server
npm install
npm run dev:public          # 公网哑服务：静态分发 adapter/catalog/revocation
npm run typecheck           # TypeScript 类型检查
npm run build               # 只生成 public 部署包，拒绝 runtime/campus
npm run smoke:all           # 迁移期 legacy baseline；V2 客户端 fixture gate 接管后瘦身
```

> `server/src/runtime` 是 V1 迁移期与审核辅助代码，不是 V2 产品 runtime。V2 adapter 的行为权威是全平台共用的客户端 QuickJS/host API；fixture 保留，但不再用 TS/Dart 双跑证明等价。

---

## 贡献一个学校 adapter

> 真实学校 adapter 现落在独立公开仓 **elecon-adapters**（本仓按 `adapters.pin` 拉取，见[「仓库结构」](#仓库结构)）。下列以模板 `adapters/_template/` 为例说明形态，实际提交面向 elecon-adapters。

1. 使用 V2 统一异步 JavaScript template 创建 `school-<你的学校id>/`；V1 declarative template 仅作迁移历史。
2. 在 `manifest.json` 完整声明能力与可能访问的所有 scheme/origin/path/method；宿主据此 fail-closed。
3. 在 `index.js` 自行读取凭证、编排学校流程并把响应归一化成 `contract/schema/` 定义的标准结构。
4. 在 `fixtures/` 放抓包样本，写归一化回归测试。
5. 在该 adapter 的 `README.md` 记录：该校属哪一档（UA 门禁 / CAS 逃生口 / openid 唯一身份 / 微信小程序）及已知坑。

**执行信任：** official 经官方门后自动受信。支持本地导入的平台在用户确认接受 exact bundle digest 前不得执行任何 bundle 代码；确认后 local unsigned 获得完整 adapter 能力。iOS 仅运行 official。

---

## 合规与安全

- **客户端是唯一私密执行面**：私密数据经 direct、系统 VPN 或 official transport/app-tunnel 从用户设备访问学校；项目不提供中继。
- **信任即完整能力**：受信 adapter 可读写全部 Credential Store 和私密响应；项目不承诺阻止其泄漏或篡改数据。
- **传输底座最高门槛**：能看到全部流量的传输底座仅接受官方签名，DEPLOY/DEV 均无 transport 侧载；dev transport 仍仅存在于 debug build。adapter 本地导入不放宽 transport。
- **显式知情同意**：启用能看到全部流量的隧道时，提供独立且更重的告知与授权流。

> 涉及第三方协议复刻（如校园 VPN）的接入，需先完成"许可证 + 协议模式 + iOS 可行性"评估，并以可热替换的传输底座形式接入，不焊死在客户端。

---

## 路线状态

架构的 Decision 与 Landing 是两个独立维度，不能用 `Accepted` 推断 `Implemented`。当前处于 **V1→V2 架构迁移期**：V2 决策已重启，runtime/contract 仍保留 V1 基线。逐项状态见 [`docs/adr/README.md`](docs/adr/README.md)，迁移顺序见 [`docs/planning/v2_migration.md`](docs/planning/v2_migration.md)。

- **保留资产**：客户端 QuickJS、OS secure store、宿主网络、fixture、标准 schema、official 签名/catalog/revocation、WebView 登录和 adapter 仓库。
- **迁移中**：Manifest/SDK V2、local digest trust、Credential Store JS API、客户端单端 fixture gate、official 审核与 LLM finding 流程。
- **待清理**：V1 declarative/dataflow/Masker、自动凭证注入、服务端 runtime 镜像和跨 runtime golden。campus relay 已决定删除。

> 状态提示：主仓旧 Xidian adapter、已签名 bootstrap、外部仓开发态三者版本不同，发布流程中需分别对待（见 roadmap §1）。

细分决策与取舍见 `docs/adr/` 索引；规则细则见 `docs/rules/`；当前计划见 `docs/planning/`。V1 实施资料已移入各目录的 `archived/v1/`。

---

## 许可证

见 [`LICENSE`](LICENSE)。注意：若接入 GPL 系第三方组件（如某些 VPN 协议复刻），需做实进程/模块边界隔离以避免传染，相关分析见对应 ADR。
